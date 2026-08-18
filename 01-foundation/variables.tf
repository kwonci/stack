variable "project" {
  type = string
}

variable "region" {
  type = string
}

variable "availability_zone" {
  description = "EBS 데이터 볼륨과 EC2 가 함께 위치할 AZ"
  type        = string
}

variable "data_volume_size" {
  description = "영속 데이터 볼륨 크기(GB). docker data-root 가 여기 있습니다."
  type        = number
}

variable "data_snapshot_id" {
  description = "복구용 스냅샷 ID. 비우면 빈 볼륨을 새로 만듭니다."
  type        = string
  default     = ""
}

variable "ssh_public_key_path" {
  type = string
}

# --- Cloudflare (cloudflare.tf) ---

variable "domain" {
  description = <<-EOT
    이 stack 이 점유하는 도메인. Cloudflare 에 등록된 zone 이름과 같아야 합니다.

    컨벤션: **zone 하나를 stack 하나가 통째로 씁니다.** 그래서 와일드카드가
    zone 전체를 덮고, 서비스를 추가할 때 DNS 도 터널 ingress 도 건드릴 일이
    없습니다(컨테이너의 VIRTUAL_HOST 만 정하면 됩니다).

    이 컨벤션은 취향이 아니라 TLS 가 정한 것입니다. 이름공간을 한 단계
    내리면(stack.example.com) Universal SSL 이 apex 와 1단계까지만 덮으므로
    grafana.stack.example.com 이 범위 밖이 되고, Advanced Certificate Manager
    ($10/월/zone)가 필요해집니다. 자식 zone 을 따로 두는 subdomain setup 은
    Enterprise 전용이라 대안이 못 됩니다. zone 을 나눠 써야 한다면 도메인을
    하나 더 등록하는 쪽이 훨씬 쌉니다.
  EOT
  type        = string
}

variable "cloudflare_api_token" {
  description = "Zone:DNS:Edit, Zone:Zone:Read, Zone:Transform Rules:Edit, Account:Cloudflare Tunnel:Edit, Account:Access Apps and Policies:Edit 권한이 필요합니다."
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "터널과 Access 는 account 스코프입니다. 대시보드 우측 하단 또는 URL 에서 확인."
  type        = string
}

variable "access_emails" {
  description = "Grafana 와 SSH 에 접근할 수 있는 이메일 목록. 비우면 아무도 못 들어갑니다."
  type        = list(string)

  validation {
    condition     = length(var.access_emails) > 0
    error_message = "access_emails 가 비어 있으면 Access 정책이 모두를 차단해 SSH 조차 불가능해집니다."
  }
}

variable "origin_secret" {
  description = "Cloudflare 를 거치지 않은 요청을 origin 이 걸러내는 공유 비밀. nginx 쪽 값과 같아야 합니다."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.origin_secret) >= 32
    error_message = "origin_secret 은 32자 이상이어야 합니다 (openssl rand -hex 32)."
  }
}
