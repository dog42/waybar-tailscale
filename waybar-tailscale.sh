#!/usr/bin/env bash

MENU_CMD="walker --dmenu -p Menue" # Change to rofi/fuzzel/dmenu as needed

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

_format_peers() {
  local status_json="$1"
  local ip_index="$2"
  local html="$3"
  local use_fqdn="$4"

  jq -r --arg Index "$ip_index" --argjson html "$html" --argjson fqdn "${use_fqdn:-false}" '
    [ .Peer[]? ] as $all |
    ( [ $all[] | select(.Online) ]       | sort_by(.DNSName) ) +
    ( [ $all[] | select(.Online | not) ] | sort_by(.DNSName) ) |
    .[] |
    (if .Online then "● " else "○ " end) as $dot |
    (if $fqdn then (.DNSName | rtrimstr(".")) else (.DNSName | split(".")[0]) end) as $host |
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

  jq -r --arg Index "$ip_index" --argjson html "$html" --argjson fqdn "${use_fqdn:-false}" '
    .MagicDNSSuffix as $suffix |
    ([.Self] + [.Peer[]?]) | .[] | .CapMap | select(. != null) | to_entries[] | select(.key | startswith("services/")) | .value[] |
    (.Name | sub("^svc:"; "")) as $name |
    (if $fqdn then $name + "." + $suffix else $name end) as $display_name |
    (if $Index != "" then " (" + .Addrs[$Index|tonumber] + ")" else "" end) as $ip |
    ("★ " + $display_name + $ip) as $text |
    if $html then
      "<span color=\"#7aa2f7\">" + $text + "</span>"
    else
      $text
    end
  ' <<<"$status_json" | sort
}

get_node() {
  local status_json raw_peers raw_services selected_line selected_host node_data ip4 ip6 domain options target selected_option
  status_json=$(tailscale status --json) || return 1

  # Format peers and services for picker (using short names, no IP)
  raw_peers=$(_format_peers "$status_json" "" false false)
  raw_services=$(_format_services "$status_json" "" false false)

  selected_line=$(printf "%s\n%s" "$raw_peers" "$raw_services" | grep . | sort -k2 -f | $MENU_CMD) || exit 0

  if [[ "$selected_line" == "★ "* ]]; then
    # Service selected
    selected_host="${selected_line#★ }"
    local suffix=$(jq -r '.MagicDNSSuffix' <<<"$status_json")
    domain="$selected_host.$suffix"
    
    options=$(jq -r --arg name "svc:$selected_host" '
      ([.Self] + [.Peer[]?]) | .[] | .CapMap | select(. != null) | to_entries[] | select(.key | startswith("services/")) | .value[] |
      select(.Name == $name) |
      .Addrs[]
    ' <<<"$status_json")
    options="$domain"$'\n'"$options"
  else
    # Peer selected
    selected_host="${selected_line#[●○] }"
    
    IFS=$'\t' read -r domain ip4 ip6 <<<"$(jq -r --arg host "$selected_host" '
      ([.Self] + [.Peer[]?]) | .[] | select((.DNSName | split(".")[0]) == $host) | 
      [.DNSName, .TailscaleIPs[0], .TailscaleIPs[-1]] | @tsv
    ' <<<"$status_json")"
    domain="${domain%.}"
    options="$domain"$'\n'"$ip4"$'\n'"$ip6"
  fi

  target=$(echo "$options" | $MENU_CMD) || exit 0
  selected_option=$(echo -e "copy\nopen" | $MENU_CMD) || exit 0

  if [[ $selected_option == "open" ]]; then
    xdg-open "https://$target"
  elif [[ $selected_option == "copy" ]]; then
    if command -v wl-copy &>/dev/null; then
      echo -n "$target" | wl-copy
    elif command -v xclip &>/dev/null; then
      echo -n "$target" | xclip -selection clipboard
    else
      echo "Kopiert (Fallback): $target"
      exit 0
    fi
  fi
}

_menue() {
  local selected
  selected=$(declare -F | sed -e 's/declare -f //' -e '/^_/d' | $MENU_CMD) || exit 0  # Blendet alle internen Funktionen aus (die mit "_" starten)
  $selected
}

_print_status() {
  local status_json ip_index tailnet peers services self exitnode
  
  status_json=$(tailscale status --json) || return 1

  if jq -e '.BackendState == "Running"' <<<"$status_json" >/dev/null; then
    case "${1,,}" in
      ipv4) ip_index="0" ;;
      ipv6) ip_index="-1" ;;
      *)    ip_index="" ;;
    esac

    tailnet=$(tailscale switch --list --json | jq -r '.[] | select(.selected == true) | .tailnet')
    
    peers=$(_format_peers "$status_json" "$ip_index" true)
    services=$(_format_services "$status_json" "$ip_index" true)

    self=$(jq -r --arg Index "$ip_index" '
      "<span>● " + (.Self.DNSName | split(".")[0]) + 
      (if $Index != "" then " (" + .TailscaleIPs[$Index|tonumber] + ")" else "" end) + "</span>"
      ' <<<"$status_json")

    exitnode=$(jq -r '.Peer[]? | select(.ExitNode == true).DNSName | split(".")[0]' <<<"$status_json")

    jq -nc --arg txt " exit-node: ${exitnode:-none}" \
           --arg tip "Tailnet: ""$tailnet""${exitnode:+$'\n'"Exit-Node: $exitnode"}"$'\n\n'"$self"$'\n'"$peers"${services:+$'\n\n'"Services:"$'\n'"$services"} \
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