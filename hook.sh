#!/bin/bash
# /etc/dehydrated/hooks/hetzner-cloud/hook.sh
#
# dehydrated hook for Hetzner Cloud DNS API
# Supports DNS-01 challenges, including wildcard certificates.
#
# Dependencies: bash, curl, jq, dig
# Token file: /etc/hetzner-dns-token

set -Eeuo pipefail

API_BASE="https://api.hetzner.cloud/v1"
TOKEN_FILE="${HETZNER_DNS_TOKEN_FILE:-/etc/hetzner-dns-token}"
DNS_TTL="${HETZNER_DNS_TTL:-300}"
DNS_RESOLVER="${HETZNER_DNS_RESOLVER:-7.7.7.7}"
DNS_WAIT_TIMEOUT="${HETZNER_DNS_WAIT_TIMEOUT:-180}"

log() {
    printf '[hetzner-hook] %s\n' "$*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

api() {
    curl --silent --show-error --fail-with-body \
        --connect-timeout 10 \
        --max-time 30 \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H 'Content-Type: application/json' \
        "$@"
}

normalize_domain() {
    local d="${1%.}"
    d="${d#\*.}"
    printf '%s' "${d,,}"
}

# Find the longest matching zone in the Hetzner account.
find_zone() {
    local domain="$1"
    local zones

    zones="$(api "${API_BASE}/zones?per_page=100")" ||
        die "Could not retrieve Hetzner DNS zones"

    printf '%s' "$zones" |
        jq -er --arg d "$domain" '
            [
                .zones[]
                | . as $z
                | select(
                    $d == $z.name
                    or ($d | endswith("." + $z.name))
                  )
            ]
            | sort_by(.name | length)
            | last
            | [.id, .name]
            | @tsv
        ' || die "No matching Hetzner DNS zone for ${domain}"
}

# Calculate the TXT record name relative to its zone.
challenge_name() {
    local domain="$1"
    local zone="$2"
    local prefix=""

    if [[ "$domain" != "$zone" ]]; then
        prefix="${domain%."$zone"}"
        prefix="${prefix%.}"
    fi

    if [[ -n "$prefix" ]]; then
        printf '_acme-challenge.%s' "$prefix"
    else
        printf '_acme-challenge'
    fi
}

challenge_fqdn() {
    local name="$1"
    local zone="$2"
    printf '%s.%s' "$name" "$zone"
}

# Wait for a public recursive resolver to return our TXT value.
wait_for_dns() {
    local fqdn="$1"
    local value="$2"
    local start=$SECONDS
    local deadline=$((SECONDS + DNS_WAIT_TIMEOUT))
    local server answer attempt
    local all_found

    local -a nameservers=(
        hydrogen.ns.hetzner.com
        oxygen.ns.hetzner.com
        helium.ns.hetzner.de
    )

    log "Waiting up to ${DNS_WAIT_TIMEOUT}s for TXT propagation at ${fqdn}"

    attempt=0

    while (( SECONDS < deadline )); do
        attempt=$((attempt + 1))
        all_found=1

        for server in "${nameservers[@]}"; do
            answer="$(
                dig +time=3 +tries=1 +short TXT "$fqdn" "@${server}" \
                    2>/dev/null |
                sed 's/^"//; s/"$//'
            )" || answer=""

            if ! printf '%s\n' "$answer" | grep -Fxq -- "$value"; then
                all_found=0
                break
            fi
        done

        if (( all_found )); then
            log "TXT record visible on all authoritative nameservers after $((SECONDS - start))s"
            return 0
        fi

        log "Attempt ${attempt}: waiting for authoritative DNS ($((SECONDS - start))s elapsed)"
        sleep 3
    done

    log "Timed out waiting for ${fqdn}"
    log "Expected challenge value: ${value}"
    die "TXT record not visible on all authoritative nameservers after ${DNS_WAIT_TIMEOUT}s"
}

deploy_challenge() {
    local domain tokenfile value normalized zone_info
    local zone_id zone_name rrset fqdn payload response http_code action_id
    local existing

    domain="${1:?Missing domain}"
    tokenfile="${2:-}"
    value="${3:?Missing challenge value}"

    normalized="$(normalize_domain "$domain")"
    zone_info="$(find_zone "$normalized")"
    IFS=$'\t' read -r zone_id zone_name <<< "$zone_info"

    rrset="$(challenge_name "$normalized" "$zone_name")"
    fqdn="$(challenge_fqdn "$rrset" "$zone_name")"

    log "Checking for existing TXT records at ${fqdn}"

    # A missing RRset is normal; create it in that case.
    http_code="$(curl -sS \
        -o /tmp/hetzner-rrset.json \
        -w '%{http_code}' \
        --connect-timeout 10 \
        --max-time 30 \
        -H "Authorization: Bearer ${API_TOKEN}" \
        "${API_BASE}/zones/${zone_id}/rrsets/${rrset}/TXT")" ||
        die "Could not query Hetzner TXT RRset"

    existing="$(cat /tmp/hetzner-rrset.json)"

    payload="$(jq -n \
        --arg value "\"${value}\"" \
        --argjson ttl "$DNS_TTL" \
        '{ttl: $ttl, records: [{value: $value}]}'
    )"

    if [[ "$http_code" == "200" ]]; then
        # Preserve existing values and add this challenge.
        response="$(api -X POST \
            "${API_BASE}/zones/${zone_id}/rrsets/${rrset}/TXT/actions/add_records" \
            --data "$(jq -n --arg value "\"${value}\"" \
                '{records: [{value: $value}]}')")" ||
            die "Failed to add TXT value at ${fqdn}"
    elif [[ "$http_code" == "404" ]]; then
        log "RRset does not exist; creating it"

        response="$(api -X POST \
            "${API_BASE}/zones/${zone_id}/rrsets" \
            --data "$(jq -n \
                --arg name "$rrset" \
                --arg value "\"${value}\"" \
                --argjson ttl "$DNS_TTL" \
                '{name: $name, type: "TXT", ttl: $ttl,
                  records: [{value: $value}]}')")" ||
            die "Failed to create TXT RRset at ${fqdn}"
    else
        printf '%s\n' "$existing" >&2
        die "Unexpected HTTP ${http_code} querying TXT RRset"
    fi

    # Wait for the asynchronous Hetzner action, if one was returned.
    action_id="$(printf '%s' "$response" | jq -r '.action.id // empty')"

    if [[ -n "$action_id" ]]; then
        log "Waiting for Hetzner action ${action_id}"

        while :; do
            response="$(api "${API_BASE}/actions/${action_id}")" ||
                die "Failed to query Hetzner action ${action_id}"

            case "$(printf '%s' "$response" | jq -r '.action.status')" in
                success)
                    break
                    ;;
                error)
                    printf '%s\n' "$response" >&2
                    die "Hetzner action ${action_id} failed"
                    ;;
                running)
                    sleep 2
                    ;;
                *)
                    printf '%s\n' "$response" >&2
                    die "Unexpected status for Hetzner action ${action_id}"
                    ;;
            esac
        done
    fi

    wait_for_dns "$fqdn" "$value"
}

clean_challenge() {
    local domain tokenfile value normalized zone_info
    local zone_id zone_name rrset fqdn payload

    domain="${1:?Missing domain}"
    tokenfile="${2:-}"
    value="${3:?Missing challenge value}"

    normalized="$(normalize_domain "$domain")"
    zone_info="$(find_zone "$normalized")"
    IFS=$'\t' read -r zone_id zone_name <<< "$zone_info"

    rrset="$(challenge_name "$normalized" "$zone_name")"
    fqdn="$(challenge_fqdn "$rrset" "$zone_name")"

    payload="$(jq -n \
        --arg value "\"${value}\"" \
        '{records: [{value: $value}]}'
    )"

    log "Removing our TXT challenge value from ${fqdn}"

    api -X POST \
        "${API_BASE}/zones/${zone_id}/rrsets/${rrset}/TXT/actions/remove_records" \
        --data "$payload" >/dev/null ||
        die "Failed to remove TXT value at ${fqdn}"

    chown root:caddy /var/lib/dehydrated/certs -R
    chmod 770 /var/lib/dehydrated/certs
    chmod 770 /var/lib/dehydrated/certs/21x9.org
    chmod 660 /var/lib/dehydrated/certs/21x9.org/*
}

main() {
    local handler="${1:-}"
    shift || true

    [[ -r "$TOKEN_FILE" ]] ||
        die "Cannot read API token file: ${TOKEN_FILE}"

    API_TOKEN="$(<"$TOKEN_FILE")"
    [[ -n "$API_TOKEN" ]] || die "API token file is empty"

    case "$handler" in
        deploy_challenge)
            deploy_challenge "$@"
            ;;
        clean_challenge)
            clean_challenge "$@"
            ;;
        exit_hook)
            exit_hook "$@"
            ;;
        startup_hook|unchanged_cert|invalid_challenge|request_failure|generate_csr|deploy_cert|sync_cert)
            # Recognized dehydrated hooks not implemented here.
            return 0
            ;;
        this_hookscript_is_broken__dehydrated_is_working_fine__please_ignore_unknown_hooks_in_your_script)
            return 0
            ;;
        *)
            echo "Unsupported handler: ${handler:-<empty>}"
            return 0
            ;;
    esac
}

exit_hook() {
    local exit_code="${1:-0}"

    if [[ "$exit_code" -eq 0 ]]; then
        log "dehydrated finished successfully"
    else
        log "dehydrated finished with exit code ${exit_code}"
    fi

    return 0
}

main "$@"
