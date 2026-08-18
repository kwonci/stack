# 도메인 앞단. AWS 쪽 리소스와 provider 만 다를 뿐 수명은 같습니다 —
# 전부 `make down` 에도 살아남아야 하는 것들이라 같은 레이어에 있습니다.
# 파일을 나눈 것은 읽기 편하라고 그런 것이지 경계가 아닙니다.
#
# 대시보드에서 손으로 하던 네 가지가 여기 있습니다.
#   - DNS 레코드      : 전부 터널을 가리키는 CNAME (와일드카드 + 관리 평면)
#   - 터널            : cloudflared 가 붙을 터널과 그 ingress 규칙
#   - Access          : ssh/grafana 앞의 인증
#   - Transform Rule  : origin 이 CF 경유 여부를 판별할 비밀 헤더
#
# zone 자체는 만들지 않습니다. 도메인 등록과 zone 이전은 이 stack 밖의 일입니다.
#
# 컨벤션: zone 하나를 stack 하나가 통째로 점유합니다. var.domain 이 곧 zone 이고,
# 와일드카드가 zone 전체를 덮습니다. 이유는 variables.tf 의 domain 설명 참고
# (요약: 이름공간을 한 단계 내리면 Universal SSL 범위 밖이라 유료 인증서가 필요).

data "cloudflare_zone" "main" {
  filter = {
    name = var.domain
  }
}

locals {
  # 관리 평면 호스트. 터널로만 닿고 Access 가 앞을 막습니다.
  # service 는 호스트 안에서 본 주소입니다 — cloudflared 가 호스트에서 돌기 때문입니다.
  tunnel_hosts = {
    ssh     = "ssh://localhost:22"
    grafana = "http://localhost:3000"
  }

  # 공개 평면. 나머지 전부를 nginx-proxy(03-proxy) 로 넘깁니다. 그 안에서 어느
  # 컨테이너가 응답할지는 컨테이너의 VIRTUAL_HOST 가 정하므로, 서비스를 하나
  # 늘릴 때 이 레이어를 apply 할 필요가 없습니다.
  public_service = "http://localhost:80"
}

# --- 터널 ---

resource "cloudflare_zero_trust_tunnel_cloudflared" "main" {
  account_id = var.cloudflare_account_id
  name       = var.project
  # 대시보드가 아니라 여기서 ingress 를 관리한다는 뜻입니다.
  config_src = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "main" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.main.id

  # cloudflared 는 위에서 아래로 처음 맞는 규칙을 씁니다. 따라서 관리 평면이
  # 반드시 와일드카드보다 앞에 와야 합니다 — 순서가 뒤집히면 ssh.<domain> 이
  # nginx-proxy 로 가서 SSH 가 통째로 죽습니다.
  config = {
    ingress = concat(
      [
        for name, service in local.tunnel_hosts : {
          hostname = "${name}.${var.domain}"
          service  = service
        }
      ],
      # hostname 선두의 와일드카드만 지원됩니다(test.*.example.com 은 불가).
      # 여러 단계(a.b.<domain>)도 이 규칙에 걸리지만, Universal SSL 인증서는
      # 한 단계까지만 덮으므로 그런 호스트를 쓰려면 Advanced Certificate Manager 가
      # 필요합니다. apex(<domain> 자체)는 와일드카드에 포함되지 않습니다.
      [{
        hostname = "*.${var.domain}"
        service  = local.public_service
      }],
      # ingress 의 마지막 규칙은 hostname 없는 catch-all 이어야 합니다.
      # 없으면 Cloudflare 가 설정을 거부합니다.
      [{ service = "http_status:404" }]
    )
  }
}

# cloud-init 이 쓸 토큰. 02-compute 가 output 으로 받아 갑니다.
data "cloudflare_zero_trust_tunnel_cloudflared_token" "main" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.main.id
}

# --- DNS ---

# 공개 평면. EIP 가 아니라 터널을 가리킵니다 — origin 에는 인바운드 규칙이
# 하나도 없으므로 EIP 로 향하는 레코드는 어차피 아무 데도 닿지 못합니다.
#
# proxied 는 선택이 아니라 필수입니다. cfargotunnel.com 은 CF 엣지 안에서만
# 의미가 있어서, 회색 구름으로 두면 레코드가 해석되지 않습니다.
#
# 이 CNAME 은 같은 CF 계정 안에서만 동작합니다. 터널 UUID 가 알려져도 남이
# 자기 계정에 이 레코드를 만들어 트래픽을 끌어올 수 없습니다.
resource "cloudflare_dns_record" "wildcard" {
  zone_id = data.cloudflare_zone.main.zone_id
  name    = "*.${var.domain}"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.main.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1 # proxied 레코드는 TTL 을 CF 가 정하므로 1(auto) 이어야 합니다.
}

# 관리 평면. 위 와일드카드와 같은 곳을 가리키므로 DNS 해석만 놓고 보면 없어도
# 됩니다. 그래도 명시하는 이유는 두 가지입니다: 더 구체적인 레코드가 와일드카드를
# 이기므로 의도가 드러나고, 나중에 와일드카드를 좁히거나 지워도 관리 평면은
# 계속 살아 있습니다.
resource "cloudflare_dns_record" "tunnel" {
  for_each = local.tunnel_hosts

  zone_id = data.cloudflare_zone.main.zone_id
  name    = "${each.key}.${var.domain}"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.main.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

# --- Access ---
# 터널은 hostname 을 인터넷에 공개할 뿐 인증을 붙이지 않습니다.
# 이 정책이 없으면 ssh.<domain> 과 grafana.<domain> 이 그냥 열립니다.

resource "cloudflare_zero_trust_access_policy" "owner" {
  account_id = var.cloudflare_account_id
  name       = "${var.project}-owner"
  decision   = "allow"

  # include 의 항목들은 OR 로 묶입니다. 목록 전체를 펼쳐야 두 번째 이메일부터도
  # 들어올 수 있습니다.
  include = [
    for e in var.access_emails : {
      email = {
        email = e
      }
    }
  ]
}

resource "cloudflare_zero_trust_access_application" "tunnel" {
  for_each = local.tunnel_hosts

  zone_id          = data.cloudflare_zone.main.zone_id
  name             = "${var.project}-${each.key}"
  domain           = "${each.key}.${var.domain}"
  type             = "self_hosted"
  session_duration = "24h"

  policies = [{
    id         = cloudflare_zero_trust_access_policy.owner.id
    precedence = 1
  }]
}

# --- Transform Rule ---
# origin 에 인바운드 규칙이 없어진 뒤로는 "CF 를 우회한 직접 접속"이라는 위협
# 자체가 사라졌으므로, 이 헤더는 더 이상 필수 방어선이 아닙니다. 남겨둔 것은
# nginx 쪽(03-proxy/vhost.d/default)의 검증과 짝이고 비용이 없기 때문입니다.
# 지울 거라면 반드시 양쪽을 함께 지우세요 — 한쪽만 지우면 전부 403 이 됩니다.
resource "cloudflare_ruleset" "origin_secret" {
  zone_id = data.cloudflare_zone.main.zone_id
  name    = "${var.project} origin secret"
  kind    = "zone"
  phase   = "http_request_late_transform"

  rules = [{
    # 조건을 좁히면 걸러진 경로의 요청이 origin 에서 403 이 됩니다. 전부에 붙입니다.
    expression  = "true"
    action      = "rewrite"
    description = "origin 이 CF 경유를 확인할 수 있도록 비밀 헤더를 붙입니다"

    action_parameters = {
      headers = {
        "X-Origin-Secret" = {
          operation = "set"
          value     = var.origin_secret
        }
      }
    }
  }]
}
