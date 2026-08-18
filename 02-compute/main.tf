# 02-compute
# 껐다 켜지는 레이어. `make down` == 이 레이어만 destroy.
# 여기 있는 리소스는 전부 재생성 가능하며 영속 상태를 담지 않습니다.

terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project = var.project
      Source  = "github.com/kwonci/stack/02-compute"
      Managed = "terraform"
    }
  }
}

data "terraform_remote_state" "foundation" {
  backend = "s3"

  config = {
    bucket = var.tfstate_bucket
    key    = "01-foundation/terraform.tfstate"
    region = var.region
  }
}


locals {
  fnd = data.terraform_remote_state.foundation.outputs
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd*/ubuntu-resolute-26.04-${var.instance_arch}-server-*"]
  }
}

resource "aws_instance" "main" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type

  subnet_id              = local.fnd.subnet_id
  vpc_security_group_ids = [local.fnd.security_group_id]
  key_name               = local.fnd.key_name

  # 브레이크글라스. 이 프로필이 없으면 SSM 에 등록되지 않고, 터널이 죽었을 때
  # 호스트에 닿을 방법이 아예 사라집니다. (01-foundation/main.tf 참고)
  iam_instance_profile = local.fnd.iam_instance_profile_name

  # 공개 서브넷 + 공인 IP 입니다. 인바운드를 받기 위해서가 아니라 **내보내기**
  # 위해서입니다 — cloudflared 는 region1.v2.argotunnel.com:7844 로, SSM 에이전트는
  # ssm/ssmmessages/ec2messages 엔드포인트로 나가야 하고, apt 와 docker pull 도
  # 인터넷을 씁니다. 공인 IP 가 없으면 이 서브넷에는 NAT 이 없어 전부 끊깁니다.
  #
  # 사설 서브넷으로 옮겨도 보안이 나아지지 않습니다. 인바운드 규칙이 이미 0 개라
  # 지금도 도달 가능한 리스너가 없고, 사설 서브넷은 그 대신 NAT 요금을 붙일 뿐입니다
  # (ap-northeast-2 기준 NAT Gateway $0.059/시간 = 월 $43 + 데이터 처리 요금.
  #  자동 할당 공인 IPv4 는 $0.005/시간 = 월 $3.65). 스택 전체가 월 $6.5 인데
  # NAT 하나가 그 7배입니다.
  #
  # VPC 엔드포인트로 NAT 을 대신하는 길도 없습니다. SSM 은 엔드포인트 3개로
  # 되지만(월 $28) Cloudflare 엣지는 AWS 서비스가 아니라 엔드포인트가 없어서
  # cloudflared 가 아예 뜨지 못합니다.
  associate_public_ip_address = true

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  # credit_specification 은 일부러 지정하지 않습니다(= AWS 기본값 unlimited).
  # standard 로 두면 t4g 는 launch credit 을 받지 못해 새 인스턴스가 0 크레딧에서
  # baseline 0.4 vCPU 로 시작하고, 매 make up 의 docker 설치가 스로틀에 걸립니다.
  # unlimited 는 24시간 평균이 baseline 을 넘을 때만 과금되는데, 이 정도 부하로는
  # 거의 그럴 일이 없습니다. 대신 폭주하면 조용히 청구되니 가끔 확인하세요.

  # 인터넷에 노출된 리버스 프록시가 같은 호스트에 있으므로, SSRF 로 IMDS 를
  # 긁는 경로를 미리 막습니다. hop_limit 1 이면 컨테이너에서 닿지 않습니다.
  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  user_data = templatefile("${path.module}/cloud-init.yaml", {
    data_volume_id          = local.fnd.data_volume_id
    cloudflare_tunnel_token = local.fnd.tunnel_token
  })

  # user_data 가 바뀌면 인스턴스를 새로 만듭니다.
  # 어차피 모든 영속 데이터는 EBS 에 있으므로 재생성이 안전합니다.
  user_data_replace_on_change = true

  tags = {
    Name = "${var.project}-host"
  }

  lifecycle {
    # Canonical 이 새 AMI 를 내면 most_recent 가 바뀌어 `make up` 이
    # 멀쩡한 인스턴스를 조용히 교체해 버립니다. 재빌드는 down/up 으로 명시적으로.
    ignore_changes = [ami]
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = local.fnd.data_volume_id
  instance_id = aws_instance.main.id

  # 없으면 destroy 가 detach 대기에서 멈춥니다. 다만 terraform 은 인스턴스를
  # 종료하기 *전에* attachment 를 지우므로, 이것만 믿으면 마운트된 볼륨을 그대로
  # 뜯게 됩니다. scripts/lib.sh 의 quiesce_host 가 먼저 도는 것이 전제입니다.
  force_detach = true
}
