#!/usr/bin/env bash

# MENU_CMD="wofi --dmenu --prompt 'Menue'" # Change to rofi/fuzzel/dmenu as needed
MENU_CMD="walker --dmenu 'Menue'" # Change to rofi/fuzzel/dmenu as needed

tailscale_status() {
  tailscale status --json | jq -e '.BackendState == "Running"' >/dev/null
}

toggle_status() {
  if tailscale_status; then
    tailscale down
  else
    tailscale up
  fi
  sleep 3
}

select_exit_node() {
  if ! tailscale_status; then
    notify-send -a "Tailscale" "VPN is not running"
    return 1
  fi

  # Get available exit nodes (devices that advertise as exit nodes)
  local nodes
  nodes=$(tailscale status --json | jq -r '
        .Peer[] | select(.ExitNodeOption == true) |
        .DNSName')

  # Add option to disable exit node
  nodes="None (disable exit node)"$'\n'"$nodes"

  # Show menu and get selection
  local selected
  selected=$(echo "$nodes" | $MENU_CMD)

  [ -z "$selected" ] && return 0 # User cancelled

  if [[ "$selected" == "None"* ]]; then
    tailscale set --exit-node=
    notify-send -a "Tailscale" "Exit node disabled"
  else
    tailscale set --exit-node="$selected"
    notify-send -a "Tailscale" "Exit node set to: $selected"
  fi
}

switch_tailnet() {
  local tailnets
  local active
  tailnets=$(tailscale switch --list --json | jq -r '
    .[].tailnet')
  active=$(tailscale switch --list --json | jq -r '
    .[] | select(.selected == true) | .tailnet')

  tailnets="keep $active (active)"$'\n'"$tailnets"

  local selected
  selected=$(echo "$tailnets" | $MENU_CMD)

  [ -z "$selected" ] && return 0 # User cancelled

  if [[ "$selected" == "keep"* ]]; then
    notify-send -a "Tailscale" "keep Tailnet: $active"
  else
    tailscale switch $selected
    notify-send -a "Tailscale" "switch to Tailnet: $selected"
  fi
}

copy_node_ip() {
  tailscale_json=$(tailscale status --json)

  walker_input=$(echo "$tailscale_json" | jq -r '
    [ .Peer[] ] as $all
    | ( [ $all[] | select(.Online) ] | sort_by(.HostName) ) +
      ( [ $all[] | select(.Online | not) ] | sort_by(.HostName) )
    | .[]
    | if .Online then "● \(.HostName)" else "○ \(.HostName) (offline)" end')

  selected_line=$(echo "$walker_input" | walker --dmenu)

  if [ -z "$selected_line" ]; then
    exit 0
  fi

  selected_host=$(echo "$selected_line" | sed -E 's/^[●○] //; s/ \(offline\)//')

  if [ -z "$selected_host" ]; then
    exit 0
  fi

  node_data=$(echo "$tailscale_json" | jq -r --arg host "$selected_host" '.Peer[] | select(.HostName == $host)')
  ip=$(echo "$node_data" | jq -r '.TailscaleIPs[0]')
  domain=$(echo "$node_data" | jq -r '.DNSName')

  options="$ip"$'\n'"$domain"

  selected_option=$(echo "$options" | walker --dmenu)

  if [ -z "$selected_option" ]; then
    exit 0
  fi

  target=$(echo "$selected_option" | sed 's/.*: //')

  if command -v wl-copy &>/dev/null; then
    echo -n "$target" | wl-copy
  elif command -v xclip &>/dev/null; then
    echo -n "$target" | xclip -selection clipboard
  else
    echo "Kopiert (Fallback): $target"
    exit 0
  fi
}

menue() {
  local selected
  selected=$(declare -F | sed 's/declare -f //' | sed '/menue/d' | sed '/tailscale_status/d' | $MENU_CMD)
  echo $selected
  $selected
}

case $1 in
--status)
  if tailscale_status; then
    T="green"
    F="red"
    I="none"
    colors=()

    for arg in "${@:2}"; do
      arg_lower=$(echo "$arg" | tr '[:upper:]' '[:lower:]' | tr -d '\n')

      case "$arg_lower" in
      ipv4 | ipv6)
        I="$arg_lower"
        ;;
      *)
        if [[ -n "$arg" ]]; then
          colors+=("$arg")
        fi
        ;;
      esac
    done

    if [ ${#colors[@]} -ge 1 ]; then T="${colors[0]}"; fi
    if [ ${#colors[@]} -ge 2 ]; then F="${colors[1]}"; fi

    status_json=$(tailscale status --json)

    tailnet=$(tailscale switch --list --json | jq -r '
    .[] | select(.selected == true) | .tailnet')

    case "$I" in
    ipv4) ip_index="0" ;;
    ipv6) ip_index="-1" ;;
    *) ip_index="" ;;
    esac

    if [[ -n "$ip_index" ]]; then
      peers=$(jq -r --arg T "$T" --arg F "$F" --arg Index "$ip_index" '
                    .Peer[]? | 
                    "<span color=\"" + (if .Online then $T else $F end) + "\">" + 
                    (.DNSName | split(".")[0]) + ": (" + .TailscaleIPs[$Index|tonumber] + ")</span>"
                ' <<<"$status_json")
      self=$(jq -r ' "<span>" + (.Self.DNSName | split(".")[0]) + ": ("+ .Self.TailscaleIPs[0] + ")</span>"
                ' <<<"$status_json")
    else
      peers=$(jq -r --arg T "$T" --arg F "$F" '
                    .Peer[]? | 
                    "<span color=\"" + (if .Online then $T else $F end) + "\">" +
                    (.DNSName | split(".")[0]) + "</span>"
                ' <<<"$status_json")
      self=$(jq -r ' "<span>" + (.Self.DNSName | split(".")[0]) + "</span>"
                ' <<<"$status_json")
    fi

    exitnode=$(jq -r '.Peer[]? | select(.ExitNode == true).DNSName | split(".")[0]' <<<"$status_json")
    jq -nc --arg txt " exit-node: ${exitnode:-none}" --arg tip "Tailnet: ""$tailnet""${exitnode:+$'\n'"Exit-Node: $exitnode"}"$'\n\n'"$self"$'\n'"$peers" \
      '{"text": $txt, "class": "connected", "alt": "connected", "tooltip": $tip}'
  else
    echo "{\"text\":\"\",\"class\":\"stopped\",\"alt\":\"stopped\", \"tooltip\": \"The VPN is not active.\"}"
  fi
  ;;
--toggle)
  toggle_status
  ;;
--select-exit-node)
  select_exit_node
  ;;
--switch-tailnet)
  switch_tailnet
  ;;
--menue)
  menue
  ;;
esac
