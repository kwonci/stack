output "instance_id" {
  description = "SSM 복구 경로가 이 값을 대상으로 씁니다 (scripts/lib.sh)."
  value       = aws_instance.main.id
}

output "public_ip" {
  description = "자동 할당 주소. 인스턴스를 재생성할 때마다 바뀝니다."
  value       = aws_instance.main.public_ip
}

output "ssh" {
  # 직접 ssh 하면 전용 known_hosts 와 -i 옵션이 빠져 재생성 후 host key 거부에
  # 걸립니다. 래퍼를 쓰세요.
  value = "make ssh"
}
