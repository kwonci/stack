output "data_volume_id" {
  value = aws_ebs_volume.data.id
}

output "security_group_id" {
  value = aws_security_group.main.id
}

output "key_name" {
  value = aws_key_pair.main.key_name
}

output "iam_instance_profile_name" {
  description = "SSM Session Manager 복구 경로. 02 가 인스턴스에 붙입니다."
  value       = aws_iam_instance_profile.ssm.name
}

output "subnet_id" {
  value = data.aws_subnet.default.id
}

# --- Cloudflare ---

output "tunnel_token" {
  description = "02-compute 의 cloud-init 이 cloudflared 에 넘깁니다."
  value       = data.cloudflare_zero_trust_tunnel_cloudflared_token.main.token
  sensitive   = true
}

output "tunnel_id" {
  value = cloudflare_zero_trust_tunnel_cloudflared.main.id
}

output "zone_id" {
  description = "레코드를 직접 추가할 때 쓰라고 남겨둡니다."
  value       = data.cloudflare_zone.main.zone_id
}

output "managed_hostnames" {
  description = "Access 뒤에 있는 관리 평면 호스트"
  value       = [for k, _ in local.tunnel_hosts : "${k}.${var.domain}"]
}
