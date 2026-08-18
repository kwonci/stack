.PHONY: bootstrap up down deploy nuke ssh logs snapshot destroy-data plan fmt validate

# 최초 1회: tfstate 를 담을 S3 버킷 생성
bootstrap:
	@scripts/bootstrap.sh

# stack 켜기 (01 -> 02 -> 호스트 배포). 멱등.
up:
	@scripts/up.sh

# stack 끄기 (EC2 만 destroy, 데이터/IP 는 유지. DNS 는 Cloudflare 관리라 대상이 아님)
down:
	@scripts/down.sh

# 인프라는 그대로 두고 compose stack 만 다시 배포 (이미지 pull 포함)
deploy:
	@scripts/deploy.sh

# 데이터 볼륨 스냅샷을 지금 하나 만들기
snapshot:
	@scripts/snapshot.sh

# 데이터 볼륨만 파괴 (스냅샷에서 되돌릴 때). make down 이 선행되어야 합니다.
destroy-data:
	@scripts/destroy-data.sh

# 데이터 볼륨과 EIP 까지 전부 파괴 (Cloudflare 쪽은 건드리지 않음)
nuke:
	@scripts/nuke.sh

# make ssh                  -> 셸
# make ssh ARGS='docker ps' -> 원격 실행
ssh:
	@scripts/ssh.sh $(ARGS)

# make logs S=03-proxy
logs:
	@scripts/logs.sh $(S)

# apply 없이 01/02 변경분 확인
plan:
	@scripts/plan.sh

fmt:
	@terraform fmt -recursive

# AWS 없이 문법 검사 (.env 없어도 동작)
validate:
	@scripts/validate.sh
