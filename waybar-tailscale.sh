#!/usr/bin/env bash

MENU_CMD="walker --dmenu -p Menue" # Change to rofi/fuzzel/dmenu as needed
TERM_CMD="kitty"                   # Change to your preferred terminal emulator
SSH_USER=""                        # SSH login user; empty = let ssh decide (~/.ssh/config / local user)

toggle_status() {
  if tailscale status --json | jq -e '.BackendState == "Running"' >/dev/null; then
    tailscale down
  else
    tailscale up
  fi
  sleep 3
}

select_exit_node() {
  local status_json nodes selected selected_node
  status_json=$(tailscale status --json) || return 1
  if ! jq -e '.BackendState == "Running"' <<<"$status_json" >/dev/null; then
    notify-send -a "Tailscale" "VPN is not running"
    return 1
  fi

  nodes=$(jq -r '
    [ .Peer[]? | select(.ExitNodeOption == true) ] as $nodes |
    (any($nodes[]; .ExitNode)) as $has_active |
    (if $has_active then "○ " else "● " end + "None (disable exit node)") as $none_opt |
    $none_opt, ($nodes[] | (if .ExitNode then "● " else "○ " end) + (.DNSName | rtrimstr(".")))
  ' <<<"$status_json")

  selected=$(echo "$nodes" | $MENU_CMD) || exit 0

  if [[ "$selected" == *"None (disable exit node)" ]]; then
    tailscale set --exit-node=
    notify-send -a "Tailscale" "Exit node disabled"
  else
    selected_node="${selected#[●○] }"
    tailscale set --exit-node="$selected_node"
    notify-send -a "Tailscale" "Exit node set to: $selected_node"
  fi
}

switch_tailnet() {
  local list tailnets selected selected_tailnet
  list=$(tailscale switch --list --json) || return 1
  tailnets=$(jq -r '.[] | (if .selected then "● " else "○ " end) + .tailnet' <<<"$list")

  selected=$(echo "$tailnets" | $MENU_CMD) || exit 0
  selected_tailnet="${selected#[●○] }"

  if [[ "$selected" == "● "* ]]; then
    notify-send -a "Tailscale" "Tailnet $selected_tailnet is already active"
  else
    tailscale switch "$selected_tailnet"
    notify-send -a "Tailscale" "switch to Tailnet: $selected_tailnet"
  fi
}

# Shared jq helpers for peer handling
# - peers:        all valid peers; ignores stale engine-only peers (e.g. after "tailscale switch"): no name, no IPs, not in netmap
# - short_name:   first DNS label ("host" of "host.tailnet.ts.net.")
# - display_name($all): short name, or "host.tailnet" if the short name is not unique among $all
_JQ_PEER_DEFS='
  def peers: [ .Peer[]? | select(.InNetworkMap != false and (.DNSName // "") != "") ];
  def short_name: .DNSName | split(".")[0];
  def display_name($all):
    short_name as $s |
    if ([ $all[] | select(short_name == $s) ] | length) > 1
    then .DNSName | rtrimstr(".") | split(".")[0:2] | join(".")
    else $s end;
'

_format_peers() {
  local status_json="$1"
  local ip_index="$2"
  local html="$3"
  local use_fqdn="$4"

  jq -r --arg Index "$ip_index" --argjson html "$html" --argjson fqdn "${use_fqdn:-false}" "$_JQ_PEER_DEFS"'
    peers as $all |
    ( [ $all[] | select(.Online) ]       | sort_by(.DNSName) ) +
    ( [ $all[] | select(.Online | not) ] | sort_by(.DNSName) ) |
    .[] |
    (if .Online then "● " else "○ " end) as $dot |
    (if $fqdn then (.DNSName | rtrimstr(".")) else display_name($all) end) as $host |
    (if $Index != "" then " (" + .TailscaleIPs[$Index|tonumber] + ")" else "" end) as $ip |
    ($dot + $host + $ip) as $text |
    if $html then
      "<span color=\"" + (if .Online then "green" else "red" end) + "\">" + $text + "</span>"
    else
      $text
    end
  ' <<<"$status_json"
}

_format_services() {
  local status_json="$1"
  local ip_index="$2"
  local html="$3"
  local use_fqdn="$4"
  local live_check="${5:-false}"
  local raw_lines line online name text check_ip check_port
  local -a lines=() on_lines=() off_lines=()

  raw_lines=$(jq -r --arg Index "$ip_index" --argjson html "$html" --argjson fqdn "${use_fqdn:-false}" "$_JQ_PEER_DEFS"'
    .MagicDNSSuffix as $suffix |
    ([.Self] + peers) as $all |
    # a service may be advertised by several nodes -> show each service only once
    [ $all[] | .CapMap | select(. != null) | to_entries[] | select(.key | startswith("services/")) | .value[]? | select(.Name != null) ]
    | unique_by(.Name) | sort_by(.Name) | .[] |
    . as $svc |
    (.Name | sub("^svc:"; "")) as $name |
    (if $fqdn then $name + "." + $suffix else $name end) as $display_name |
    (if $Index != "" then " (" + (.Addrs[$Index|tonumber] // "?") + ")" else "" end) as $ip |
    [ $all[] | . as $n | select(any(($svc.Addrs // [])[]; . as $sip | (($n.AllowedIPs // []) + ($n.PrimaryRoutes // [])) | any(startswith($sip)))) ] as $hosts |
    (if ($hosts | length) > 0 then ([ $hosts[] | display_name($all) ] | unique | join(",")) else "" end) as $host_str |
    (if ($hosts | length) > 0 then any($hosts[]; .Online) else true end) as $host_online |
    (if $host_str != "" then " [" + $host_str + "]" else "" end) as $host_tag |
    (($svc.Addrs // [])[0] // "") as $first_ip |
    ([ ($svc.Ports // [])[] | select(startswith("tcp:")) | sub("^tcp:"; "") ][0] // "") as $first_port |
    [
      (if $host_online then "1" else "0" end),
      $name,
      ($display_name + $ip + $host_tag),
      $first_ip,
      $first_port
    ] | @tsv
  ' <<<"$status_json")

  [[ -z "$raw_lines" ]] && return 0

  if [[ "$live_check" == "true" ]]; then
    local tmpdir
    tmpdir=$(mktemp -d)
    while IFS=$'\t' read -r online name text check_ip check_port; do
      if [[ "$online" == "1" && -n "$check_ip" && -n "$check_port" ]]; then
        (
          if timeout 0.3 bash -c "</dev/tcp/$check_ip/$check_port" 2>/dev/null; then
            echo "1" >"$tmpdir/$name"
          else
            echo "0" >"$tmpdir/$name"
          fi
        ) &
      else
        echo "$online" >"$tmpdir/$name"
      fi
      lines+=("$online"$'\t'"$name"$'\t'"$text")
    done <<<"$raw_lines"
    wait

    for line in "${lines[@]}"; do
      IFS=$'\t' read -r online name text <<<"$line"
      [[ -f "$tmpdir/$name" ]] && online=$(<"$tmpdir/$name")
      if [[ "$online" == "1" ]]; then
        on_lines+=("$text")
      else
        off_lines+=("$text")
      fi
    done
    rm -rf "$tmpdir"
  else
    while IFS=$'\t' read -r online name text check_ip check_port; do
      if [[ "$online" == "1" ]]; then
        on_lines+=("$text")
      else
        off_lines+=("$text")
      fi
    done <<<"$raw_lines"
  fi

  for text in "${on_lines[@]}"; do
    if [[ "$html" == "true" ]]; then
      printf '<span color="#7aa2f7">★ %s</span>\n' "$text"
    else
      printf '★ %s\n' "$text"
    fi
  done
  for text in "${off_lines[@]}"; do
    if [[ "$html" == "true" ]]; then
      printf '<span color="red">☆ %s</span>\n' "$text"
    else
      printf '☆ %s\n' "$text"
    fi
  done
}

get_node() {
  local status_json raw_peers raw_services selected_line selected_host ip4 ip6 domain suffix has_ssh options available_actions target selected_option
  status_json=$(tailscale status --json) || return 1

  # Format peers and services for picker (using short names, no IP)
  raw_peers=$(_format_peers "$status_json" "" false false)
  raw_services=$(_format_services "$status_json" "" false false true)

  # Order: online peers, offline peers (both alphabetical, see _format_peers), then services
  selected_line=$(printf "%s\n%s" "$raw_peers" "$raw_services" | grep . | $MENU_CMD) || exit 0

  if [[ "$selected_line" == [★☆]" "* ]]; then
    # Service selected (strip leading star and trailing " [node]" tag)
    selected_host="${selected_line#[★☆] }"
    selected_host="${selected_host% \[*\]}"
    suffix=$(jq -r '.MagicDNSSuffix' <<<"$status_json")
    domain="$selected_host.$suffix"

    options=$(jq -r --arg name "svc:$selected_host" '
      ([.Self] + [.Peer[]?]) | .[] | .CapMap | select(. != null) | to_entries[] | select(.key | startswith("services/")) | .value[]? |
      select(.Name == $name) |
      .Addrs[]?
    ' <<<"$status_json" | awk '!seen[$0]++') # keep every distinct IP, drop exact duplicates
    options="$domain"$'\n'"$options"
    available_actions="copy\nopen"
  else
    # Peer selected
    selected_host="${selected_line#[●○] }"

    IFS=$'\t' read -r domain ip4 ip6 has_ssh <<<"$(jq -r --arg label "$selected_host" "$_JQ_PEER_DEFS"'
      peers as $all | first($all[] | select(display_name($all) == $label)) |
      (if (.sshHostKeys != null and (.sshHostKeys | length > 0)) then "true" else "false" end) as $has_ssh |
      [.DNSName, .TailscaleIPs[0], .TailscaleIPs[-1], $has_ssh] | @tsv
    ' <<<"$status_json")"
    domain="${domain%.}"
    # Drop empty values and duplicates (peers with a single IP have ip4 == ip6)
    options=$(printf "%s\n" "$domain" "$ip4" "$ip6" | awk 'NF && !seen[$0]++')
    available_actions="copy\nopen"
    if [[ "$has_ssh" == "true" ]]; then
      available_actions+="\nssh"
    fi
  fi

  target=$(echo "$options" | $MENU_CMD) || exit 0
  selected_option=$(echo -e "$available_actions" | $MENU_CMD) || exit 0

  if [[ $selected_option == "open" ]]; then
    if [[ "$target" == *:* ]]; then
      xdg-open "https://[$target]" # IPv6 literals need brackets in URLs
    else
      xdg-open "https://$target"
    fi
  elif [[ $selected_option == "copy" ]]; then
    if command -v wl-copy &>/dev/null; then
      echo -n "$target" | wl-copy
    elif command -v xclip &>/dev/null; then
      echo -n "$target" | xclip -selection clipboard
    else
      echo "Kopiert (Fallback): $target"
      exit 0
    fi
  elif [[ $selected_option == "ssh" ]]; then
    $TERM_CMD -e ssh "${SSH_USER:+$SSH_USER@}$target"
  fi
}

_menue() {
  local selected
  selected=$(declare -F | sed -e 's/declare -f //' -e '/^_/d' | $MENU_CMD) || exit 0 # Blendet alle internen Funktionen aus (die mit "_" starten)
  $selected
}

_print_status() {
  local status_json version ip_index tailnet peers services self exitnode

  if ! status_json=$(tailscale status --json 2>/dev/null); then
    echo "{\"text\":\"\",\"class\":\"stopped\",\"alt\":\"stopped\", \"tooltip\": \"tailscaled is not running.\"}"
    return 0
  fi
  version=$(tailscale version --json | jq -r ".short")

  if jq -e '.BackendState == "Running"' <<<"$status_json" >/dev/null; then
    case "${1,,}" in
    ipv4) ip_index="0" ;;
    ipv6) ip_index="-1" ;;
    *) ip_index="" ;;
    esac

    tailnet=$(tailscale switch --list --json | jq -r '.[] | select(.selected == true) | .tailnet')
    peers=$(_format_peers "$status_json" "$ip_index" true)
    services=$(_format_services "$status_json" "$ip_index" true)

    self=$(jq -r --arg Index "$ip_index" '
      "<span>● " + (.Self.DNSName | split(".")[0]) + 
      (if $Index != "" then " (" + .Self.TailscaleIPs[$Index|tonumber] + ")" else "" end) + "</span>"
      ' <<<"$status_json")

    exitnode=$(jq -r '.Peer[]? | select(.ExitNode == true).DNSName | split(".")[0]' <<<"$status_json")

    jq -nc --arg txt " exit-node: ${exitnode:-none}" \
      --arg tip "Tailnet: ""$tailnet""${exitnode:+$'\n'"Exit-Node: $exitnode"}"$'\n\n'"$self"$'\n'"  @ v""$version"$'\n'"$peers"${services:+$'\n\n'"Services:"$'\n'"$services"} \
      '{"text": $txt, "class": "connected", "alt": "connected", "tooltip": $tip}'
  else
    echo "{\"text\":\"\",\"class\":\"stopped\",\"alt\":\"stopped\", \"tooltip\": \"The VPN is not active.\"}"
  fi
}

case $1 in
--status) _print_status "$2" ;;
--toggle) toggle_status ;;
--select-exit-node) select_exit_node ;;
--switch-tailnet) switch_tailnet ;;
--menue) _menue ;;
--get-node) get_node ;;
esac
