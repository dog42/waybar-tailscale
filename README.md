<h1>
    <p align="center">
waybar-tailscale
</p>
</h1>
<p align="center">
    a simple module to manage <a href="https://tailscale.com/"><b>Tailscale</b></a> on <a href="https://github.com/Alexays/Waybar"><b>Waybar</b></a>
    <br>
    fork from <a href="https://github.com/federicovolponi/waybar-tailscale"><b>federicovolponi</b></a>
</p>

<p align="center">
  <img src="https://github.com/dog42/waybar-tailscale/blob/main/assets/tooltip.png?raw=true" alt="Waybar Tooltip Status" width="400" />
</p>

## What can it do?

- Show Tailscale status and your online and offline devices
- Toggle on/off the VPN
- Interactive menu (right-click) to:
  - Select and toggle exit nodes
  - Switch between tailnets
  - Copy IP/DNS or open peer node web interfaces (Admin, etc.)
  - Toggle VPN status

## Installation

Initially, you need to be able to use Tailscale without using `sudo`. You can do that by executing:

```bash
tailscale set --operator=$USER
```

After, you can clone the repository in your Waybar's configuration folder, or where you prefer.

## Configuration

In your waybar `config.json` add a new module, as shown in the example below.

```json
"custom/tailscale" : {
    "exec": "~/.config/waybar/waybar-tailscale/waybar-tailscale.sh --status ipv4",
    "on-click": "exec ~/.config/waybar/waybar-tailscale/waybar-tailscale.sh --toggle",
    "on-click-right": "exec ~/.config/waybar/waybar-tailscale/waybar-tailscale.sh --menue",
    "exec-on-event": true,
    "format": "         ",
    // uncomment if you want icons, don't use with tailscale.css
    // "format": "VPN {icon}",
    // "format-icons": {
    //     "connected": "󱠾 󰕥 ",
    //     "stopped": "󱠾  "
    // },
    "tooltip": true,
    "return-type": "json",
    "interval": 1,
},
```

**Important!** Be sure to insert the correct path to the script in the _exec_,  _on-click_, and _on-click-right_ fields.
The script is executed every second, but you can easily change it by modifying the _interval_ field.

If you want the tailscale-logo (and not icons) add the next line on top of your waybar `style.css` (don't use with "format-icons" in waybar `config.json`)

```
@import "waybar-tailscale/tailscale.css";
```

### Menu Selection

You can use right-click to open the interactive menu. From there, you can choose to toggle connection status, select an exit node, switch your tailnet, or copy/open peer nodes.
`walker` is currently set to display the menu, but you can update `MENU_CMD` in the script to any of the below based on what you have installed:

<p align="center">
  <img src="https://github.com/dog42/waybar-tailscale/blob/main/assets/menue.png?raw=true" alt="Interactive Menu Selection" width="450" />
</p>

`walker` is currently set to display the menu, but you can update `MENU_CMD` in the script to any of the below based on what you have installed:

```bash
walker --dmenu -p Menue
wofi --dmenu --prompt 'Menue'
rofi -dmenu -p 'Menue'
fuzzel --dmenu --prompt 'Menue'
dmenu -p 'Menue'
```
The individual menu items can also be called directly with corresponding flags for the script:

```bash
waybar-tailscale.sh --menue
waybar-tailscale.sh --toggle
waybar-tailscale.sh --select-exit-node
waybar-tailscale.sh --switch-tailnet
waybar-tailscale.sh --get-node
```


### Adding IP to the tooltip

By default, no IP address will be shown in the tooltip. If you want to see the `ipv4` or `ipv6` addresses, pass one of the following arguments to the script:

```bash
waybar-tailscale.sh --status ipv4
waybar-tailscale.sh --status ipv6
```

## Contributing

Even if this is a very trivial module, feel free to propose new features and point out any problems!
