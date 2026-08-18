# stack

EC2 + docker-compose + nginx-proxy + Cloudflare 위에 올린 개인 stack.

두 가지 원칙으로 만들어졌습니다.

1. **언제든 껐다 킬 수 있다.** `make down` 은 EC2 만 파괴하고, `make up` 은 같은 호스트명·같은 데이터로 되살립니다. 공인 IP 는 인스턴스와 함께 반납되지만, 모든 이름이 IP 가 아니라 터널을 가리키므로 바뀌어도 손댈 것이 없습니다. 모든 상태는 코드(terraform + compose) 아니면 EBS 볼륨에 있고, 그 둘 다 재현 가능합니다.
2. **의존성 순서대로 번호를 붙인다.** 낮은 번호가 먼저 서고, 파괴는 역순입니다. 전역 리소스는 `00-`.

용어: `00`–`02` 는 terraform 이 만드는 **레이어**, `03` 이상은 호스트에서 도는 compose **호스트 stack** 입니다. (프로젝트 전체를 가리킬 때도 "stack" 이라 부릅니다 — 문맥으로 구분하세요.)

## 결과적으로 무엇이 되었나

EC2 한 대에 개인 서비스를 올리되, **인터넷에서 그 호스트로 들어오는 문은 하나도 열지 않은** 배치입니다.

- **인바운드 규칙 0개.** 공개 서비스도 Grafana 도 SSH 도, 호스트의 cloudflared 가 Cloudflare 엣지로 걸어 나간 연결을 되타고 들어옵니다.
- **인증서·포트·고정 IP 를 다룰 일이 없습니다.** TLS 는 엣지가 끝내고 origin 은 루프백 평문 HTTP 만 말합니다. acme-companion 도, 80/443 인바운드도, EIP 도 없습니다.
- **서비스 추가는 compose 파일 하나.** 컨테이너에 `VIRTUAL_HOST` 를 달면 `*.<DOMAIN>` → 터널 → nginx-proxy 를 타고 바로 붙습니다. DNS 도 터널 ingress 도 `terraform apply` 도 필요 없습니다.
- **껐다 켜도 그대로.** `make down` 은 EC2 만 버리고 데이터(EBS)·DNS·터널·Access 는 남깁니다. `make up` 이 같은 호스트명·같은 데이터로 되살립니다.
- **잠겨도 들어갈 길이 하나 더 있습니다.** Cloudflare 쪽이 죽어도 SSM Session Manager 로 들어가고, 그 경로는 인바운드 개방도 `terraform apply` 도 요구하지 않습니다.
- **클릭으로 만드는 것이 없습니다.** 도메인 등록과 zone 이전을 빼면 터널·ingress·DNS·Access·Transform Rule 이 전부 `01-foundation/cloudflare.tf` 안에 있습니다.
- **꺼둔 상태 월 $2.7, 켜면 $23 안팎** (ap-northeast-2 온디맨드, t4g.small 기준. 근거는 아래 "비용").

## 구성

| | 무엇 | 도구 | `make down` 시 |
|---|---|---|---|
| `00-global` | 나머지 레이어의 tfstate 를 담는 S3 버킷 | terraform | **유지** |
| `01-foundation` | EBS 볼륨, SG, key pair, SSM IAM 역할 + Cloudflare 전체(레코드·터널·Access·Rule) | terraform | **유지** |
| `02-compute` | EC2, 볼륨 attach | terraform | **파괴** |
| `03-proxy` | nginx-proxy (터널 뒤의 vhost 라우터, TLS 없음) | compose | **볼륨만 유지** |
| `04-monitoring` | Prometheus + Grafana + node-exporter | compose | **볼륨만 유지** |

경계는 `01` 과 `02` 사이에 있습니다. `01` 은 잃으면 아픈 것(데이터·도메인 앞단), `02` 는 언제든 버려도 되는 것.

zone 자체는 이 stack 밖입니다 — 도메인 등록과 Cloudflare 로의 zone 이전은 손으로 합니다. 그 안의 레코드·터널·Access·Rule 은 `01-foundation/cloudflare.tf` 가 관리합니다.

**번호는 provider 가 아니라 수명을 뜻합니다.** `01` 에 AWS 와 Cloudflare provider 가 함께 있는 것은 둘 다 `make down` 에 살아남아야 하기 때문입니다. Cloudflare 를 별도 레이어로 떼면 번호가 "어느 provider 인가"를 뜻하게 되어, `make down` 이 무엇을 남기는지가 번호에서 안 읽히게 됩니다. 파일만 나눠 두었습니다.

터널이 `01` 에 있는 실용적 이점도 있습니다. 터널 토큰이 cloud-init 으로 들어가야 호스트의 cloudflared 가 뜨는데, `01` 이 `02` 보다 먼저 서므로 자연히 순서가 맞고 대시보드에서 토큰을 복사해 `.env` 에 붙여넣는 수작업이 없습니다.

이 배치에는 함정이 하나 있었습니다. 복구 경로가 SG 규칙이던 시절에는 그 규칙과 Cloudflare 리소스가 같은 apply 안에 있어서, **Cloudflare 가 고장나 복구가 필요한 바로 그 상황에서 apply 가 Cloudflare 단계에서 멈췄습니다.** 복구 수단이 복구 대상에 의존한 셈입니다. 지금은 복구 경로가 SSM 이라 복구 시점에 apply 자체가 필요 없고, 이 문제가 없습니다.

## 보안 경계

**인터넷에서 이 호스트로 들어오는 인바운드 경로는 없습니다.** SG 의 인바운드 규칙은 0 개이고, 공개 서비스든 Grafana 든 SSH 든 전부 호스트의 cloudflared 가 Cloudflare 엣지로 *걸어 나간* 연결을 되타고 들어옵니다. Cloudflare 가 터널 배포에 권장하는 구성 그대로입니다 — 인그레스를 전부 막고 cloudflared 의 이그레스만 허용.

두 평면은 여전히 성격이 다릅니다. 다른 것은 인증뿐입니다.

| | 공개 평면 | 관리 평면 |
|---|---|---|
| 무엇 | 누구나 보는 서비스 | Grafana, SSH |
| DNS | `*.<domain>` CNAME → `<tunnel-id>.cfargotunnel.com` | `grafana`/`ssh` CNAME → 같은 터널 |
| 터널 ingress | `*.<domain>` → `http://localhost:80` (nginx-proxy) | `ssh://localhost:22`, `http://localhost:3000` |
| 인증 | 없음 (공개) | Cloudflare Access |
| TLS | Cloudflare 가 종료. origin 구간은 터널 자체가 암호화 | 동일 |

**터널 ingress 는 위에서 아래로 처음 맞는 규칙을 씁니다.** 그래서 `ssh`/`grafana` 규칙이 반드시 `*.<domain>` 와일드카드보다 앞에 와야 합니다. 순서가 뒤집히면 `ssh.<domain>` 이 nginx-proxy 로 가서 SSH 가 통째로 죽습니다. 마지막은 hostname 없는 `http_status:404` catch-all 이어야 하고, 없으면 Cloudflare 가 설정을 거부합니다.

**도메인 컨벤션: zone 하나를 stack 하나가 통째로 점유합니다.** `DOMAIN` 은 Cloudflare zone 이름 그 자체이고, 와일드카드 `*.<DOMAIN>` 이 zone 전체를 덮습니다. 그래서 서비스를 추가할 때 DNS 도 터널 ingress 도 건드릴 일이 없습니다 — 컨테이너에 `VIRTUAL_HOST` 만 달면 됩니다.

이건 취향이 아니라 TLS 가 정한 결론입니다. 한때 `stack.<DOMAIN>` 처럼 한 단계 내려서 zone 을 다른 용도와 나눠 쓰려 했다가 되돌렸습니다:

| 방법 | 결과 |
|---|---|
| `stack.example.com` 으로 이름공간 내리기 | Universal SSL 은 apex 와 1단계까지만 덮음 → `grafana.stack.example.com` 은 범위 밖. Cloudflare 엣지가 인증서를 제시하지 않아 **TLS 핸드셰이크 자체가 거부됨** |
| Advanced Certificate Manager 로 `*.stack.example.com` 발급 | 됨. **$10/월/zone** (= 연 $120) |
| Total TLS | ACM 이 전제라 무료 플랜 불가. 게다가 **터널을 쓰는 호스트명에는 발급하지 않음** |
| `stack.example.com` 을 자식 zone 으로 분리 | **Enterprise 전용** (Free/Pro 는 Full setup 만) |
| 접두사 와일드카드 `stack-*.example.com` | DNS 에 그런 것은 없음. 와일드카드는 레이블 하나를 통째로 대체함 |

즉 **zone 을 나눠 쓰면서 와일드카드를 유지하는 무료 방법은 없습니다.** 다른 용도와 섞어야 한다면 도메인을 하나 더 등록하는 쪽이 ACM 보다 훨씬 쌉니다.

**컨벤션의 예외는 직접 관리해야 합니다.** 이 zone 이 stack 전용이라는 전제가 깨지는 레코드 — 예를 들어 손으로 만든 `blog.<DOMAIN>` — 는 terraform 이 모릅니다. 더 구체적인 레코드가 와일드카드를 이기므로 지금은 정상 동작하지만, 그 레코드를 지우는 순간 와일드카드가 그 이름을 받아 이 stack 의 nginx-proxy 로 흘려보냅니다. zone 에 stack 밖 레코드가 있다면 `cloudflare.tf` 로 가져오거나, 최소한 있다는 사실을 알고 계세요.

**apex 는 와일드카드에 포함되지 않습니다.** `*.example.com` 은 `example.com` 자신을 덮지 않으므로, apex 로 서비스를 띄우려면 DNS 레코드와 터널 ingress 규칙을 `01-foundation/cloudflare.tf` 에 따로 추가해야 합니다.

**`X-Origin-Secret` 은 이제 필수가 아닙니다.** 예전에는 SG 를 CF 엣지 대역으로 좁혀 80/443 을 열어두었고, 그 대역이 CF 전 고객 공용이라 "남의 CF 계정을 경유한 우회"가 남아 이 헤더 검증이 그 구멍을 막았습니다. 인바운드가 0 이 된 지금은 우회할 직접 경로 자체가 없습니다. 비용이 없어 한 겹으로 남겨 두었을 뿐이니, 지운다면 Transform Rule(`01-foundation/cloudflare.tf`)과 `scripts/lib.sh` 의 `render_proxy_secret` 을 **함께** 지우세요. 한쪽만 없애면 모든 요청이 403 이 됩니다.

**origin 에 인증서가 없습니다.** cloudflared 는 같은 호스트의 `127.0.0.1:80` 으로 붙으므로 그 구간에 TLS 를 걸 이유가 없고, 그래서 acme-companion 도 Let's Encrypt 도 이 stack 에 없습니다. 80 번 인바운드를 열었던 유일한 이유가 HTTP-01 챌린지였으므로 그것도 함께 사라졌습니다. 터널로 들어오는 트래픽에는 zone 의 SSL/TLS 암호화 모드(Full/Flexible 등)가 적용되지 않습니다 — 설정할 것이 없습니다.

**EIP 는 없습니다.** 인바운드 규칙이 0 개가 된 뒤로 고정 주소가 필요한 곳이 복구 경로 하나뿐이었는데, 그 자리를 SSM 이 가져가면서 이유가 사라졌습니다. 인스턴스는 기본 서브넷의 자동 할당 공인 IP 를 받습니다 — 이 서브넷에는 NAT 이 없어 공인 IP 가 없으면 아웃바운드가 끊기고, 그러면 cloudflared 도 SSM 도 붙지 못하기 때문입니다. 인바운드는 SG 가 막고 있으므로 주소가 있다는 것 자체는 노출이 아닙니다. 비용도 같습니다 — AWS 는 사용 중인 EIP 와 자동 할당 IPv4 에 동일하게 시간당 요금을 매깁니다.

**사설 서브넷으로 옮길 이유도 없습니다.** 공개 서브넷에 있는 것은 트래픽을 받기 위해서가 아니라 내보내기 위해서입니다 — cloudflared 는 `region1.v2.argotunnel.com:7844` 로, SSM 에이전트는 SSM 엔드포인트로 나가야 하고, apt 와 docker pull 도 인터넷을 씁니다. 인바운드 규칙이 이미 0 개이므로 사설 서브넷으로 옮겨도 도달 가능한 리스너가 늘거나 줄지 않고, NAT 요금만 붙습니다.

| 구성 | ap-northeast-2 월 비용 | 동작 |
|---|---|---|
| 공개 서브넷 + 자동 할당 IPv4 (현재) | $3.65 | 전부 동작 |
| 사설 서브넷 + NAT Gateway | $43 + 데이터 처리 | 전부 동작 |
| 사설 서브넷 + VPC 엔드포인트만 | $28 (엔드포인트 3개) | **cloudflared 가 뜨지 못함** |

세 번째 줄이 핵심입니다. Cloudflare 엣지는 AWS 서비스가 아니라 VPC 엔드포인트가 존재하지 않으므로, NAT 없이 사설 서브넷에 두면 터널 자체가 성립하지 않습니다. 켜둔 스택 전체가 월 $23 인데 NAT 게이트웨이 하나가 월 $43 로 그보다 큽니다.

**잠겼을 때 — SSM Session Manager.** 터널이 죽어도 SG 를 열 필요가 없습니다.

```bash
SSH_VIA=ssm make ssh
SSH_VIA=ssm make ssh ARGS='journalctl -u cloudflared -n 50'
SSH_VIA=ssm make down          # 볼륨을 안전하게 내리는 것까지 그대로 동작합니다
```

`SSH_VIA=ssm` 은 `ssh` 의 ProxyCommand 를 `cloudflared access ssh` 에서 `aws ssm start-session --document-name AWS-StartSSHSession` 으로 바꾸고, 접속 대상을 `ssh.<domain>` 에서 인스턴스 ID 로 바꿉니다. **SSH 자체는 같은 key pair 로 붙으므로 `rsync` 와 `quiesce_host` 까지 그대로 동작합니다** — 조회만 되는 것이 아니라 `make deploy` 도 `make down` 도 이 경로로 됩니다. `.env` 에 적는 값이 아니라 그때그때 붙이는 환경변수입니다.

이것이 제대로 된 브레이크글라스인 이유는 실패 도메인이 겹치지 않기 때문입니다.

| | 평상시 경로 (터널) | 복구 경로 (SSM) |
|---|---|---|
| Cloudflare 의존 | 있음 | **없음** |
| 인바운드 포트 | 불필요 | 불필요 |
| 복구 시점에 `terraform apply` | — | **불필요** (역할이 이미 붙어 있음) |
| 에이전트 출처 | `stack-init.sh` 가 설치 | **AMI 에 이미 있음** (snap) |
| 요금 | — | **없음** (EC2 에서 Session Manager 는 무료) |

마지막 줄이 중요합니다. `stack-init.sh` 는 `set -euxo pipefail` 이라 중간에 죽을 수 있고(예: cloudflared 다운로드 실패), 그러면 cloudflared 도 docker 도 없는 호스트가 남습니다. SSM 에이전트는 그 스크립트와 무관하게 AMI 에서 이미 돌고 있으므로 그 상태에서도 들어갈 수 있습니다. cloud-init 의 `runcmd` 첫 줄이 에이전트를 한 번 더 확인하지만, 어느 단계가 실패해도 부팅을 막지 않도록 전부 실패를 삼킵니다.

**로컬에 `session-manager-plugin` 이 필요합니다.** awscli 와 별개 패키지이고, 없으면 `SessionManagerPlugin is not found` 로 죽습니다.

SSM 마저 안 될 때의 마지막 수단은 AWS 콘솔입니다: SG 에 22 번 인바운드를 손으로 추가하고, 인스턴스의 자동 할당 공인 IP 로 직접 `ssh -i` 하세요. terraform 은 그 규칙을 drift 로 보고 다음 apply 에서 지웁니다.

### 영속 데이터가 사는 곳

EC2 의 docker `data-root` 가 `/data/docker` — 즉 EBS 데이터 볼륨 — 로 설정되어 있습니다. 따라서 **모든 named volume 이 자동으로 영속**됩니다. Grafana DB, Prometheus TSDB, nginx vhost 설정 전부 EC2 재생성 후에도 그대로입니다. 새 stack 을 추가할 때 영속화를 위해 따로 할 일이 없습니다.

이 배치에는 조건이 하나 붙습니다: dockerd 가 `/data` 마운트보다 먼저 뜨면 루트 볼륨에 빈 data-root 를 새로 만들어 버립니다. 그래서 `docker.service` 에 `RequiresMountsFor=/data` drop-in 을 넣어 마운트 없이는 dockerd 가 시작하지 않게 했습니다.

`/opt/stack` (compose 파일)은 루트 볼륨에 있고 배포 때마다 덮어써집니다. 상태가 아니라 코드의 사본이기 때문입니다.

## 시작하기

사전 준비:

- terraform 1.11+ (`.tool-versions` 에 1.15.8 고정), awscli + 자격증명, make, bash 4+, `python3`
- `rsync` — 호스트 배포에 필요
- `dig` — NS 확인에 사용. 없으면 `make up` 이 멈춥니다
- `cloudflared` — **로컬에 필수.** 평상시 SSH 가 이걸로 들어갑니다
- `session-manager-plugin` — 복구 경로(`SSH_VIA=ssm`)에 필요. awscli 와 별개 패키지입니다
- `docker` — 로컬에서는 `make validate` 에만 필요
- 이미 **등록된 도메인** 하나와 Cloudflare 계정(무료 플랜으로 충분)
- ssh 키 쌍. `.env` 에 공개키/개인키 경로를 둘 다 적습니다.

### 1. Cloudflare 로 zone 옮기기

먼저 도메인 전체를 Cloudflare 로 옮깁니다. **zone 을 통째로 옮기는 것이므로, 이 stack 과 무관한 레코드(블로그, 메일 MX 등)까지 전부 영향을 받습니다.**

1. Cloudflare 에 zone 추가. 기존 레코드를 자동으로 가져오지만, 빠진 게 없는지 반드시 눈으로 대조하세요.
2. NS 를 도메인 등록기관에서 Cloudflare 것으로 바꿉니다. 전파는 `dig +short NS <ZONE>` 으로 확인. (위임은 zone 단위로만 일어나므로 `DOMAIN` 에 `dig NS` 를 걸면 아무것도 나오지 않습니다.)
3. SSL/TLS 모드는 건드릴 것이 없습니다. 모든 트래픽이 터널로 들어오는데, 터널 트래픽에는 zone 의 암호화 모드가 적용되지 않기 때문입니다.

DNS 레코드는 손으로 만들 것이 없습니다. `*.<DOMAIN>` 와일드카드 CNAME 을 포함해 전부 `01-foundation/cloudflare.tf` 가 터널을 가리키도록 만듭니다.

`make up` 은 NS 이전이 확인되기 전에는 terraform 을 아예 돌리지 않습니다(`scripts/lib.sh` 의 `delegated`). 위임 전에도 레코드와 터널은 만들어지지만 `<tunnel-id>.cfargotunnel.com` 은 Cloudflare 엣지 안에서만 해석되므로, 배포는 SSH 를 기다리다 7분 30초 만에 실패합니다. 원인이 드러나지 않는 그 실패 대신 앞에서 멈춥니다.

### 2. Cloudflare API 토큰 만들기

**터널도 ingress 도 DNS 도 Access 도 Transform Rule 도 대시보드에서 손으로 만들지 않습니다.** `01-foundation/cloudflare.tf` 가 전부 만듭니다. 손으로 줄 것은 토큰 하나와 account ID 뿐입니다.

My Profile > API Tokens > Create Token > Custom token 으로 다음 권한을 주세요. 하나라도 빠지면 그 리소스를 만드는 지점에서 apply 가 403 으로 멈춥니다.

| 스코프 | 권한 | 무엇에 쓰이나 |
|---|---|---|
| Account | Cloudflare Tunnel: Edit | 터널과 ingress 규칙 |
| Account | Access: Apps and Policies: Edit | `ssh`/`grafana` 앞의 인증 |
| Zone | Zone: Read | zone ID 조회 |
| Zone | DNS: Edit | 와일드카드 + 관리 평면 CNAME |
| Zone | Transform Rules: Edit | `X-Origin-Secret` 헤더 규칙 |

Zone 스코프는 이 도메인 하나로 좁혀도 됩니다. 나온 토큰을 `.env` 의 `CLOUDFLARE_API_TOKEN` 에, 대시보드 우측 하단(또는 URL)의 32자리 hex 를 `CLOUDFLARE_ACCOUNT_ID` 에 넣습니다.

`ACCESS_EMAILS` 에는 Grafana 와 SSH 에 들어올 이메일을 쉼표로 적습니다. **비면 Access 정책이 모두를 막아 SSH 조차 불가능해지므로 `make up` 이 거부합니다.**

Zero Trust 조직만은 예외로 한 번 손이 갑니다. 계정에 아직 없다면 대시보드에서 팀 이름을 정해 만들어 두세요 — terraform 이 만드는 것은 그 안의 앱과 정책이지 조직 자체가 아닙니다. 로그인 방법은 기본값인 One-time PIN 이면 충분합니다(Access 가 그 이메일로 코드를 보냅니다).

### 3. 켜기

```sh
cp .env.example .env
$EDITOR .env          # 반드시 채울 것: DOMAIN, CLOUDFLARE_API_TOKEN,
                      #   CLOUDFLARE_ACCOUNT_ID, ACCESS_EMAILS,
                      #   CF_ORIGIN_SECRET (openssl rand -hex 32),
                      #   GRAFANA_ADMIN_PASSWORD (8자 이상)
                      # 나머지는 기본값 그대로 둬도 뜹니다.

make bootstrap        # 최초 1회: tfstate 버킷 생성 + state 를 S3 로 migrate
make up
```

`make up` 은 **NS 가 Cloudflare 를 가리키지 않으면 배포 전에 멈춥니다.** 일부러 그렇게 해뒀습니다 — 공개 서비스도 Grafana 도 SSH 도 전부 `<tunnel-id>.cfargotunnel.com` 을 가리키는 CNAME 으로 닿는데, 그 레코드는 Cloudflare 엣지 안에서만 의미가 있어서 zone 권한이 넘어오기 전에는 어느 것도 해석되지 않습니다. 확인이 불가능하면 `SKIP_NS_CHECK=1 make up`.

끝나면 `https://grafana.<DOMAIN>` — Cloudflare Access 로그인을 먼저 거칩니다. `make ssh` 도 첫 실행 때 브라우저로 Access 인증을 한 번 요구하고, 그 토큰은 Access 세션 기간 동안 재사용됩니다.

## 일상적인 명령

```sh
make up        # 켜기 / 변경분 반영 (멱등)
make down      # EC2 만 파괴. 데이터·DNS·터널은 유지 (공인 IP 는 반납됨)
make deploy    # 인프라는 두고 compose stack 만 재배포 (이미지 pull 포함)
make snapshot  # 데이터 볼륨 스냅샷을 지금 하나 만들기
make destroy-data  # 데이터 볼륨만 파괴 (스냅샷 복구용). make down 이 선행되어야 함
make logs S=03-proxy
make ssh       # 호스트 셸.  make ssh ARGS='docker ps'
make plan      # apply 없이 01/02 변경분 확인
make validate  # AWS 없이 문법 검사 (.env 없어도 동작)
make fmt       # terraform fmt -recursive
make nuke      # 01+02 전부 파괴. 데이터 볼륨도, 터널·DNS·Access 도 사라집니다
```

`make down` 은 terraform destroy 전에 호스트에 접속해 컨테이너를 멈추고, docker 와 containerd 를 내린 뒤 `/data` 의 하위 마운트부터 역순으로 언마운트합니다. `systemctl stop docker` 만으로는 overlay2 마운트가 남아 언마운트가 반드시 실패하기 때문입니다. 그래도 실패하면 destroy 를 진행하지 않고 멈춥니다 — 마운트된 볼륨을 force detach 하면 파일시스템이 깨집니다.

그렇게 멈췄을 때는 OS 를 정상 종료시키면 됩니다:

```sh
make ssh ARGS='sudo shutdown -h now'
make down          # 정지된 인스턴스에서 detach 하는 것은 안전합니다
```

반대로 `make down` 이 언마운트까지는 했는데 destroy 에서 실패했다면, 호스트는 docker 가 꺼지고 `/data` 가 안 붙은 상태로 남습니다. terraform 은 이 상태를 정상으로 보므로, `make up` 이 배포 직전에 `/data` 마운트와 docker 기동을 직접 확인하고 되돌립니다.

**인스턴스를 `stop` 하지 마세요.** `aws ec2 stop-instances` 로 멈춘 상태는 terraform 이 정상으로 보기 때문에 `make up` 이 아무것도 하지 않습니다. 끄려면 `make down` 을 쓰세요.

## 서비스 추가하기

1. `05-<이름>/docker-compose.yml` 생성
2. 외부 노출이 필요하면 컨테이너에 이렇게 붙입니다:

```yaml
environment:
  VIRTUAL_HOST: myapp.${DOMAIN}
  VIRTUAL_PORT: "8080"
networks:
  - proxy          # networks: proxy: external: true
```

3. `make deploy`

DNS 도 터널 ingress 도 건드릴 필요가 없습니다. `*.<DOMAIN>` CNAME 이 터널을 가리키고, 터널의 와일드카드 규칙이 nginx-proxy 로 넘기며, nginx-proxy 가 `VIRTUAL_HOST` 를 보고 라우팅합니다. 즉 서비스를 하나 늘릴 때 `01-foundation` 을 apply 할 일이 없습니다. `.env` 의 값이 필요하면 `${VAR}` 로 참조하면 됩니다.

**관리용 서비스라면 이 방식을 쓰지 마세요.** `VIRTUAL_HOST` 를 붙이는 순간 인증 없이 인터넷에 열립니다. Grafana 처럼 나만 볼 것은 `ports:` 로 `127.0.0.1` 에만 게시하고, `01-foundation/cloudflare.tf` 의 `local.tunnel_hosts` 에 한 줄을 더하세요 — 그 map 하나에서 CNAME·터널 ingress·Access 앱이 함께 만들어지고, 새 호스트는 와일드카드보다 앞 순서에 놓입니다. 이때는 `01-foundation` 을 apply 해야 합니다. `04-monitoring` 의 grafana 서비스가 그 예시입니다.

compose 파일 맨 위에 `name:` 을 넣어 프로젝트 이름을 고정하세요. 안 그러면 프로젝트 이름이 디렉토리 이름이 되어, 나중에 번호를 바꿀 때 볼륨이 전부 고아가 됩니다.

인증서는 Cloudflare 엣지가 담당하므로 `ACME_HOST` 같은 것은 없습니다. origin 은 평문 HTTP 로만 말하고, 그 구간은 루프백입니다.

## 비용

단가는 ap-northeast-2 온디맨드 기준이고, 한 달은 AWS 관행대로 730시간(=365×24/12)으로 계산했습니다.

**아래 합계는 `.env.example` 의 기본값(`t4g.small`, `DATA_VOLUME_SIZE=30`, `ROOT_VOLUME_SIZE=20`)일 때입니다.** 볼륨 크기는 각자 다르게 잡는 값이니, 자기 `.env` 의 숫자로 다시 계산하세요 — gp3 는 크기에 정비례해서 **GB 당 월 $0.0912** 입니다. 데이터 볼륨을 100GB 로 잡았다면 그 줄만 $2.74 대신 $9.12 가 되어, 꺼둔 상태 월 $9.1 / 켜둔 상태 월 $29.8 입니다.

`make down` 으로 꺼둔 동안 남는 것:

| 리소스 | 단가 | 월 |
|---|---|---|
| EBS 데이터 볼륨 30GB gp3 | $0.0912/GB-월 | $2.74 |
| S3 tfstate | 수 KB + apply 당 요청 몇 건 | ~$0 |
| Cloudflare (zone + 터널 + Access 50인) | — | $0 |

**기본값 기준 월 $2.7 정도입니다.** 공인 IPv4 가 이 표에 없는 것이 EIP 를 걷어낸 결과입니다 — 주소는 인스턴스에 자동 할당되어 종료와 함께 반납되므로, 꺼둔 동안에는 청구 대상이 아예 없습니다. AWS 요금 항목으로 말하면 이 stack 은 `PublicIPv4:InUseAddress` 만 쓰고, 할당해 둔 채 놀리는 EIP 에 붙는 `PublicIPv4:IdleAddress` 는 쓰지 않습니다(둘 다 $0.005/시간으로 단가는 같습니다).

켜져 있는 동안:

| 리소스 | 단가 | 월 |
|---|---|---|
| t4g.small | $0.0208/시간 | $15.18 |
| EBS 데이터 볼륨 30GB gp3 | $0.0912/GB-월 | $2.74 |
| EBS 루트 볼륨 20GB gp3 | $0.0912/GB-월 | $1.82 |
| 공인 IPv4 (사용 중) | $0.005/시간 | $3.65 |

**기본값 기준 월 $23 정도입니다.** gp3 는 3000 IOPS 와 125 MB/s 가 단가에 포함되고 이 stack 은 그 이상을 프로비저닝하지 않으므로 IOPS·처리량 요금은 붙지 않습니다. 스냅샷은 위 표 어디에도 없는 별도 항목입니다 — 사용 블록 기준 $0.05/GB-월이라, `make snapshot` 이나 `final_snapshot` 을 남겨두면 그만큼 더해집니다.

이 stack 은 Route53 를 쓰지 않으므로, 예전에 만들어 둔 hosted zone 이 남아 있다면 지워서 $0.50 을 더 줄일 수 있습니다 — 다른 것이 아직 쓰고 있을 수 있으니 확인은 직접 하세요. SSM Session Manager 는 EC2 에서 무료라 복구 경로에는 요금이 붙지 않습니다(세션 로그를 S3/CloudWatch 로 보내면 그쪽에 붙으므로 켜지 않았습니다).

인스턴스 값에는 조건이 하나 붙습니다. `credit_specification` 을 지정하지 않아 AWS 기본값인 unlimited 로 뜨므로, 24시간 평균 CPU 가 baseline(20%)을 넘으면 크레딧이 추가 청구됩니다. 이 정도 부하로는 거의 넘지 않지만, 뭔가 폭주하면(침해당한 컨테이너가 채굴을 돌리는 경우 포함) 상한 없이 조용히 쌓이므로 가끔 청구서를 보세요. standard 로 바꾸면 상한은 생기지만 t4g 는 launch credit 이 없어서 매 `make up` 의 docker 설치가 0.4 vCPU 로 스로틀됩니다.

## 백업과 복구

`make snapshot` 이 데이터 볼륨 스냅샷을 즉시 하나 만듭니다. 컨테이너를 멈추지 않으므로 crash-consistent 입니다 — 대부분 괜찮지만 확실히 하려면 `make down` 직후에 찍으세요.

**중요:** `.env` 의 `DATA_SNAPSHOT_ID` 만 채우고 `make up` 해도 아무 일도 일어나지 않습니다. 볼륨에 `ignore_changes = [snapshot_id]` 가 걸려 있어 이미 존재하는 볼륨은 재생성되지 않기 때문입니다(조용히 무시됩니다). 스냅샷으로 되돌리려면 볼륨을 실제로 지워야 합니다:

```sh
make down
make destroy-data            # 되돌릴 수 있는 스냅샷 목록을 보여주고 확인을 받습니다
$EDITOR .env                 # DATA_SNAPSHOT_ID=snap-...
make up
$EDITOR .env                 # 복구 후 DATA_SNAPSHOT_ID 를 다시 비웁니다
```

정말 0 으로 만들려면 `make nuke` 입니다. 이 경우 볼륨이 실제로 파괴되므로 `final_snapshot` 이 남고, 위 절차 없이 `DATA_SNAPSHOT_ID` 만 채우고 `make up` 하면 그대로 복구됩니다.

**`make nuke` 는 `01-foundation` 을 통째로 destroy 한다는 점에서 `make down` 과 다릅니다.** 터널·DNS 레코드·Access 앱·Transform Rule 이 전부 함께 사라지고, zone 만 남습니다(그건 data source 입니다). 다시 `make up` 하면 터널이 새 UUID 로 만들어지고 레코드도 거기에 맞춰지므로 손으로 고칠 것은 없지만, Access 세션은 끊기고 처음처럼 다시 로그인해야 합니다.

## 설정

`.env` 하나가 전부입니다. `scripts/lib.sh` 가 이 파일을 읽어 `TF_VAR_*` 로 terraform 에 넘기고, 같은 파일이 EC2 로 복사되어 `docker compose --env-file` 로 쓰입니다.

각 레이어의 `terraform.tfvars` 도 `lib.sh` 가 같은 순간 같은 `.env` 에서 만듭니다. 설정이 두 군데로 갈라진 것이 아니라 파생물입니다 — `make` 래퍼 없이 `terraform -chdir=01-foundation plan` 을 직접 돌릴 수 있게 하려고 둡니다. 손으로 고치지 마세요. 다음 명령이 덮어씁니다.

`.env` 는 gitignore 되어 있고, 호스트로는 mode 600 으로 전송됩니다. `01-foundation/terraform.tfvars` 에는 Cloudflare API 토큰이 들어가므로 생성 시점에 같은 600 이 걸리고, 역시 gitignore 됩니다.

Grafana 비밀번호는 특별 취급합니다. `GF_SECURITY_ADMIN_PASSWORD` 는 Grafana DB 가 처음 만들어질 때만 반영되고, 그 DB 는 `/data` 에 남아 EC2 를 재생성해도 살아남습니다. 즉 환경변수만으로는 한 번 정해진 비밀번호가 절대 바뀌지 않습니다. 그래서 `make deploy` 가 배포할 때마다 `grafana cli admin reset-admin-password` 로 `.env` 값에 맞춥니다.

## 알아둘 것

- **arm64 기본값.** `INSTANCE_TYPE=t4g.small` + `INSTANCE_ARCH=arm64`. 둘은 반드시 맞아야 합니다. x86 으로 바꾸려면 `t3.small` + `amd64`.
- **AMI 는 고정됩니다.** 인스턴스에 `ignore_changes = [ami]` 가 걸려 있어, Canonical 이 새 이미지를 내도 `make up` 이 멀쩡한 인스턴스를 교체하지 않습니다. OS 를 갱신하려면 `make down && make up`. 컨테이너 이미지는 `make deploy` 가 매번 `pull` 하므로 태그만 올리면 반영됩니다.
- **AZ 는 바꾸지 마세요.** EBS 는 AZ 에 묶여 있습니다. `AWS_AZ` 를 바꾸면 데이터 볼륨이 재생성됩니다.
- **SG 에 인바운드 규칙이 하나도 없습니다.** 평상시에는 cloudflared 터널로, 터널이 죽으면 SSM 으로 들어갑니다(위 "보안 경계" 참고). 둘 다 안 되면 `make down` 이 거부됩니다 — 호스트를 안전하게 멈출 수 없으면 볼륨을 떼지 않습니다.
- **cloud-init 이 cloudflared 를 docker 보다 먼저 세웁니다.** 그래야 `make up` 이 몇 분씩 기다리지 않습니다. 그 설치가 실패해도 SSM 은 살아 있으므로 `SSH_VIA=ssm make ssh ARGS='journalctl -u cloudflared -n 50'` 으로 확인하세요.
- **터널 토큰은 user_data 로 전달됩니다.** 따라서 terraform state 와 IMDS 양쪽에 남습니다. 인스턴스의 `http_put_response_hop_limit = 1` 덕분에 컨테이너에서는 IMDS 에 닿지 못하지만, 호스트 root 를 잡히면 그대로 읽힙니다. 그 경우 Cloudflare 대시보드에서 터널을 지우고 새로 만드는 것이 유일한 무효화 방법입니다.
- **`make down` 중에는 Grafana 와 SSH 도 닿지 않습니다.** 터널이 인스턴스와 함께 사라지기 때문입니다. 예전에는 DNS 만 살아 있고 접속은 어차피 안 됐으니 실질적인 차이는 없지만, Cloudflare 쪽에서는 터널이 "비활성"으로 보입니다.
- **`docker.sock` 은 nginx-proxy 에 그대로 노출됩니다.** `:ro` 는 소켓 파일만 읽기전용으로 만들 뿐 Docker API 는 read-write 이므로, 이 컨테이너는 사실상 호스트 root 권한을 가집니다. nginx-proxy 의 표준 구성이라 그대로 뒀습니다. 격리하려면 `tecnativa/docker-socket-proxy` 를 앞에 두세요.
- **인터넷에 직접 노출되는 서비스는 지금 없습니다.** Grafana 는 터널 + Access 뒤로 옮겼고 Prometheus 는 내부 네트워크에만 있습니다. `VIRTUAL_HOST` 를 붙인 서비스를 추가하는 순간 그게 첫 공개 서비스가 됩니다. node-exporter 가 host network 를 쓰는 이유는 bridge 에 두면 `node_network_*` 지표가 컨테이너 veth 통계가 되어버리기 때문입니다.
- **알림은 없습니다.** Prometheus 에 alert rule 도, Alertmanager 도, Grafana contact point 도 없습니다. 대시보드는 보러 가야 보입니다. `/data` 가 꽉 차면 dockerd 전체가 멈추므로, 최소한 디스크 알림 하나는 붙이는 것을 권합니다.
- **이미지는 태그로만 고정되어 있습니다.** `make deploy` 가 매번 `pull` 하므로 같은 태그가 다시 push 되면 조용히 바뀝니다. digest 까지 고정하면 이를 막을 수 있지만, 그러면 패치가 자동으로 안 들어오는 쪽으로 뒤집힙니다. 여기서는 패치 쪽을 택했습니다.
- **node-exporter 는 호스트의 모든 인터페이스에서 9100 을 엽니다.** 인터넷에서는 SG 가 막지만, 호스트의 다른 컨테이너는 전부 읽을 수 있습니다. 어차피 nginx-proxy 가 `docker.sock` 을 쥐고 있어 그쪽이 뚫리면 더 큰 문제라, 별도 조치는 하지 않았습니다.
- **자동 백업은 없습니다.** 스냅샷은 `make snapshot` 을 직접 돌리거나 `make destroy-data` / `make nuke` 가 남기는 `final_snapshot` 뿐입니다. 정기 백업이 필요하면 `01-foundation` 에 `aws_dlm_lifecycle_policy` 를 추가하되, `copy_tags` 를 켜거나 `Project` 태그를 직접 붙이세요 — 스크립트의 스냅샷 목록이 그 태그로 거릅니다.
- **`/data` 를 키우려면 `DATA_VOLUME_SIZE` 를 올리고 `make down && make up`.** 볼륨은 그 자리에서 커지지만 파일시스템은 cloud-init 의 `resize2fs` 가 늘려 주고, 그건 인스턴스가 새로 만들어질 때만 돕니다(재부팅으로는 안 됩니다). 인스턴스를 유지한 채 늘리려면 `make ssh ARGS='sudo resize2fs $(findmnt -no SOURCE /data)'`. 줄이는 것은 AWS 가 거부하므로 apply 가 실패할 뿐 데이터는 안전합니다.
- **긴 apply 를 중간에 강제 종료하면 state lock 이 남습니다.** 이후 모든 명령이 "Error acquiring the state lock" 으로 죽습니다. 출력된 ID 로 풀어주세요: `terraform -chdir=01-foundation force-unlock <ID>` (Ctrl-C 로 정상 종료했다면 락은 자동으로 풀립니다).
