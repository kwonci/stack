# 01-foundation
# EC2 를 destroy 해도 남아 있어야 하는 것들.
# `make down` 은 이 레이어를 건드리지 않습니다.
#   - EBS 데이터 볼륨      : 모든 영속 데이터(docker volume 포함)가 여기 있음
#   - SG / key pair / IAM  : 02 가 참조
#   - Cloudflare 전체       : 레코드/터널/Access/Rule (cloudflare.tf)
#
# provider 가 둘이지만 레이어는 하나입니다. 번호가 뜻하는 것은 "무엇이 살아남는가"
# 이지 "어느 provider 인가" 가 아니기 때문입니다. Cloudflare 쪽도 전부 `make down`
# 에 살아남아야 하므로 EBS 볼륨과 같은 등급입니다.

terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # 도메인 앞단(레코드/터널/Access/Rule). cloudflare.tf 참고.
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project = var.project
      Source  = "github.com/kwonci/stack/01-foundation"
      Managed = "terraform"
    }
  }
}

# 개인 stack 이라 기본 VPC 를 그대로 씁니다. VPC 를 직접 만들 이유가 없습니다.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnet" "default" {
  vpc_id            = data.aws_vpc.default.id
  availability_zone = var.availability_zone
  default_for_az    = true
}

# --- 영속 데이터 볼륨 ---
# EBS 는 AZ 에 묶이므로 EC2 도 반드시 같은 AZ 에 떠야 합니다.
resource "aws_ebs_volume" "data" {
  availability_zone = var.availability_zone
  size              = var.data_volume_size
  type              = "gp3"
  encrypted         = true

  # 빈 값이면 새 빈 볼륨, 값이 있으면 해당 스냅샷에서 복구합니다.
  snapshot_id = var.data_snapshot_id != "" ? var.data_snapshot_id : null

  # 이 볼륨을 destroy 하면 자동으로 스냅샷을 남깁니다.
  # 실수로 전체를 날려도 DATA_SNAPSHOT_ID 로 되돌릴 수 있습니다.
  final_snapshot = true

  tags = {
    Name = "${var.project}-data"
  }

  # 기본 delete 타임아웃 10분 안에 final_snapshot 이 끝나지 않으면 destroy 가
  # 실패하고, 재시도하면 스냅샷이 하나 더 생깁니다. 30GB 첫 스냅샷은 넘길 수 있습니다.
  timeouts {
    delete = "60m"
  }

  lifecycle {
    # 스냅샷에서 복구한 뒤에는 snapshot_id 를 다시 비워도 볼륨이 재생성되면 안 됩니다.
    ignore_changes = [snapshot_id]
  }
}

# --- 접근 제어 ---
#
# 인바운드 규칙은 기본적으로 **하나도 없습니다.**
#
# 모든 서비스가 cloudflared 터널로 노출되고, cloudflared 는 Cloudflare 엣지로
# 아웃바운드 연결만 겁니다(7844/tcp+udp). 따라서 인터넷에서 이 호스트로 들어오는
# 경로 자체가 존재하지 않습니다. Cloudflare 가 터널 배포에 권장하는 구성이기도
# 합니다 ("block all ingress traffic and allow only egress from cloudflared").
#
# 예전에는 80/443 을 Cloudflare 엣지 대역으로 좁혀 열어두었습니다. 그 대역은
# CF 전 고객이 공유하므로 남의 CF 계정을 경유한 우회가 남았고, 그래서
# X-Origin-Secret 검증이 한 겹 더 필요했습니다. 리스너가 아예 없으면 두 문제가
# 함께 사라집니다.
#
# 터널이 죽었을 때의 복구 경로는 아래 IAM 역할(SSM Session Manager)입니다.
# 인바운드를 열어 되는 복구 경로는 이제 없습니다.

resource "aws_security_group" "main" {
  name        = "${var.project}-sg"
  description = "${var.project} host"
  vpc_id      = data.aws_vpc.default.id

  tags = {
    Name = "${var.project}-sg"
  }
}

# cloudflared 가 Cloudflare 엣지로 나가는 통로입니다. 이게 막히면 터널이 서지
# 않고, 그러면 호스트에 닿을 방법이 없습니다. apt/docker pull 도 여기로 나갑니다.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.main.id
  description       = "all outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- 복구 경로 (SSM Session Manager) ---
#
# 터널이 죽으면 호스트에 닿을 길이 없습니다. 예전에는 SG 에 22 번을 잠깐 여는
# 것이 그 길이었는데, 그러려면 이 레이어를 apply 해야 하고 이 레이어에는
# Cloudflare 리소스가 함께 있습니다. 즉 Cloudflare 가 고장나서 복구가 필요한
# 바로 그 상황에서 apply 가 Cloudflare 단계에서 멈췄습니다. 복구 수단이 복구
# 대상에 의존한 셈이라, 브레이크글라스의 전제(독립된 실패 도메인)를 어겼습니다.
#
# SSM 은 그 전제를 지킵니다. 아웃바운드만 쓰므로 인바운드는 계속 0 개이고,
# 복구 시점에 terraform 을 돌릴 필요가 없으며(역할은 이미 붙어 있음),
# Cloudflare 와 아무 관계가 없습니다. EC2 에서는 요금도 없습니다.
#
# 역할이 02 가 아니라 여기 있는 이유: 02 에 두면 `make down` 마다 지워졌다
# 다시 생기는데, IAM instance profile 은 생성 직후 전파가 늦어 같은 apply 안의
# 인스턴스 기동이 간헐적으로 실패합니다. SG·key pair 와 같은 자리에 둡니다.

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ssm" {
  name               = "${var.project}-ssm"
  description        = "${var.project} host - SSM Session Manager (break-glass)"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# 관리형 정책 하나면 충분합니다. 세션 로그를 S3/CloudWatch 로 보내면 그쪽에
# 요금이 붙으므로 켜지 않았습니다 — 켜려면 권한도 따로 추가해야 합니다.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm" {
  name = "${var.project}-ssm"
  role = aws_iam_role.ssm.name
}

resource "aws_key_pair" "main" {
  key_name   = "${var.project}-key"
  public_key = file(pathexpand(var.ssh_public_key_path))

  tags = {
    Name = "${var.project}-key"
  }
}
