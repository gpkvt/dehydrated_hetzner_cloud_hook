# dehydrated_hetzner_hook
Dehydrated Hook to use with Hetzner Cloud API (mainly to use DNS-01 challenges)

## Prerequisites

1. Generate an API Token for your Hetzner Cloud Account
2. Save the API Token into `/etc/hetzner-api-token`
3. `chown root:root /etc/hetzner-api-token`
4. `chmod 600 /etc/hetzner-api-token`
5. Install `curl`, `dig`, `jq` and `dehydrated`
6. Create your Domain config for dehydrated (e.g. add your Domain(s) to `/etc/dehydrated/domains.txt`)
7. Configure your Hook-Script for dehydrated (e.g. add `HOOK="/etc/dehydrated/hetzner-cloud/hook.sh"` to `/etc/dehydrated/config`)

## Install

1. Clone the repo.
2. `mkdir -p # /etc/dehydrated/hooks/hetzner-cloud/`
3. Copy or link `hook.sh` to the directory created in step 2.

## Usage

Run `dehydrated -c` as root.

## Troubleshooting DNS-01 Challenges

## Check DNS records

If you need to check if your DNS records are being set correctly run the following command while running dehydrated:

```bash
DOMAIN="YOURDOMAIN"

dig TXT _acme-challenge.$DOMAIN @hydrogen.ns.hetzner.com +short
dig TXT _acme-challenge.$DOMAIN @oxygen.ns.hetzner.com +short
dig TXT _acme-challenge.$DOMAIN @helium.ns.hetzner.de +short
```

If the output is empty the records are not set, yet. Repeat the commands until the dehydrated run is completed. If everything works fine there should be no output, then three lines of cryptic chars, then no output again.

If the output keeps empty during the whole run, there might be an issue with the API communication.

You can check the entries by running the following commands:

```bash
TOKEN="$(sudo cat /etc/hetzner-dns-token)"
DOMAIN="YOURDOMAIN"

curl -sS \
  -H "Authorization: Bearer $TOKEN" \
  "https://api.hetzner.cloud/v1/zones?per_page=100" |
  jq '.zones[] | select(.name == "'$DOMAIN'") | {id, name}'
```

The Output you receive is the internal reference for the Zone (aka Domain) we need to operate in. Use it in the following command:

```bash
TOKEN="$(sudo cat /etc/hetzner-dns-token)"
ZONE="THE_OUTPUT_FROM_PREVIOUS_CMD"

curl -sS \
  -H "Authorization: Bearer $TOKEN" \
  "https://api.hetzner.cloud/v1/zones/$ZONE/rrsets/_acme-challenge/TXT" |
  jq .
{
  "error": {
    "code": "not_found",
    "message": "404 Not Found",
    "details": null
  }
}
```

The output above confirms that there a no DNS Auth records set. Which is normal before and after the dehydration run, during the run there must be such an record (might can take some seconds before it is set).

### DNS Auth

If the authorization fails the hook script might end prematurely, leaving the TXT records need for DNS auth intact. The next run might fail as those records are already exist. You can remove them by running the following:

```bash
TOKEN="$(sudo cat /etc/hetzner-dns-token)"
DOMAIN="YOURDOMAIN"

curl -sS \
  -H "Authorization: Bearer $TOKEN" \
  "https://api.hetzner.cloud/v1/zones?per_page=100" |
  jq '.zones[] | select(.name == "'$DOMAIN'") | {id, name}'
```

The Output you receive is the internal reference for the Zone (aka Domain) we need to operate in. Use it in the following command:

```bash
TOKEN="$(sudo cat /etc/hetzner-dns-token)"
ZONE="THE_OUTPUT_FROM_PREVIOUS_CMD"

curl -sS -X DELETE \
  -H "Authorization: Bearer $TOKEN" \
  "https://api.hetzner.cloud/v1/zones/$ZONE/rrsets/_acme-challenge/TXT" |
  jq .
```

After executing wait some seconds for the changes to propagate through the DNS system. Then try to run dehydrated again.
