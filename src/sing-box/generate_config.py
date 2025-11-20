import json
import sys
import os
import re
import urllib.parse

def parse_vless(url):
    parsed = urllib.parse.urlparse(url)
    params = urllib.parse.parse_qs(parsed.query)
    
    server = parsed.hostname
    port = parsed.port
    uuid = parsed.username
    
    if uuid:
        uuid = urllib.parse.unquote(uuid)
    
    outbound = {
        "type": "vless",
        "tag": parsed.fragment if parsed.fragment else "vless-auto",
        "server": server,
        "server_port": port,
        "uuid": uuid,
        "flow": params.get("flow", [""])[0],
        "tls": {
            "enabled": True,
            "server_name": params.get("sni", [""])[0],
            # Force insecure to True to avoid "legacy Common Name" errors
            "insecure": True, 
            "utls": {
                "enabled": True,
                "fingerprint": params.get("fp", ["chrome"])[0]
            }
        },
        "packet_encoding": "xudp"
    }
    
    if params.get("security", [""])[0] == "reality":
        outbound["tls"]["insecure"] = False
        outbound["tls"]["reality"] = {
            "enabled": True,
            "public_key": params.get("pbk", [""])[0],
            "short_id": params.get("sid", [""])[0]
        }
    
    if params.get("type", ["tcp"])[0] == "ws":
        outbound["transport"] = {
            "type": "ws",
            "path": params.get("path", ["/"])[0],
            "headers": {
                "Host": params.get("host", [""])[0]
            }
        }
    elif params.get("type", ["tcp"])[0] == "grpc":
        outbound["transport"] = {
            "type": "grpc",
            "service_name": params.get("serviceName", [""])[0]
        }

    return outbound

def parse_hysteria2(url):
    parsed = urllib.parse.urlparse(url)
    params = urllib.parse.parse_qs(parsed.query)
    
    server = parsed.hostname
    port = parsed.port
    password = parsed.username
    
    if password:
        password = urllib.parse.unquote(password)
    
    outbound = {
        "type": "hysteria2",
        "tag": parsed.fragment if parsed.fragment else "hy2-auto",
        "server": server,
        "server_port": port,
        "password": password,
        "tls": {
            "enabled": True,
            "server_name": params.get("sni", [server])[0],
            # Force insecure to True
            "insecure": True if server == params.get("sni", [server])[0] else False,
            "alpn": params.get("alpn", ["h3"])[0].split(",")
        }
    }
    
    if "obfs" in params:
        outbound["obfs"] = {
            "type": "salamander",
            "password": params["obfs"][0]
        }
        
    return outbound

def parse_tuic(url):
    parsed = urllib.parse.urlparse(url)
    params = urllib.parse.parse_qs(parsed.query)
    
    server = parsed.hostname
    port = parsed.port
    uuid = parsed.username
    password = parsed.password
    
    if uuid:
        uuid = urllib.parse.unquote(uuid)
    if password:
        password = urllib.parse.unquote(password)
        
    # If password is None, maybe it was encoded in username with %3A
    if not password and uuid and ":" in uuid:
        uuid, password = uuid.split(":", 1)
    
    outbound = {
        "type": "tuic",
        "tag": parsed.fragment if parsed.fragment else "tuic-auto",
        "server": server,
        "server_port": port,
        "uuid": uuid,
        "password": password,
        "congestion_control": params.get("congestion_control", ["bbr"])[0],
        "tls": {
            "enabled": True,
            "server_name": params.get("sni", [server])[0],
            # Force insecure to True
            "insecure": True if server == params.get("sni", [server])[0] else False,
            "alpn": params.get("alpn", ["h3"])[0].split(",")
        }
    }
    
    return outbound

def parse_subscription(file_path):
    outbounds = []
    with open(file_path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            
            try:
                if line.startswith("vless://"):
                    outbounds.append(parse_vless(line))
                elif line.startswith("hysteria2://"):
                    outbounds.append(parse_hysteria2(line))
                elif line.startswith("tuic://"):
                    outbounds.append(parse_tuic(line))
                else:
                    print(f"Warning: Unsupported protocol in line: {line[:20]}...")
            except Exception as e:
                print(f"Error parsing line {line[:20]}...: {e}")
                
    return outbounds

def main():
    if len(sys.argv) < 4:
        print("Usage: python3 generate_config.py <template_path> <subscription_path> <output_path>")
        sys.exit(1)

    template_path = sys.argv[1]
    subscription_path = sys.argv[2]
    output_path = sys.argv[3]

    # Load template
    with open(template_path, 'r') as f:
        config = json.load(f)

    # Parse subscription
    outbounds = parse_subscription(subscription_path)
    
    if not outbounds:
        print("Error: No valid outbounds found in subscription file.")
        sys.exit(1)

    # 1. Inject outbounds
    config["outbounds"].extend(outbounds)
    
    # Create a selector outbound named "proxy" that includes all parsed outbounds
    outbound_tags = [o["tag"] for o in outbounds]
    
    # Check if "proxy" selector already exists (it shouldn't in our template, but good to check)
    proxy_selector = next((o for o in config["outbounds"] if o["tag"] == "proxy" and o["type"] == "selector"), None)
    
    if proxy_selector:
        proxy_selector["outbounds"].extend(outbound_tags)
    else:
        # Create new proxy selector
        proxy_selector = {
            "type": "selector",
            "tag": "proxy",
            "outbounds": outbound_tags,
            "default": outbound_tags[0] if outbound_tags else ""
        }
        # Insert at the beginning of outbounds list so it's easily accessible
        config["outbounds"].insert(0, proxy_selector)

    # 2. Fix Log Path
    # Set log output to "sing-box.log" in the work dir.
    if "log" not in config:
        config["log"] = {}
    config["log"]["output"] = "sing-box.log"
    config["log"]["level"] = "info"
    config["log"]["timestamp"] = True

     # 3. Configure Route for rule_set
    # We use remote rule sets from 2dust/sing-box-rules (compatible with Loyalsoldier)
    
    if "rule_set" in config["route"]:
        new_rule_sets = []
        for rs in config["route"]["rule_set"]:
            tag = rs["tag"]
            # Determine download URL based on tag
            # Tags in template are like "geosite-category-ads-all", "geoip-cn"
            filename = f"{tag}.srs"
            download_url = f"https://cdn.gh-proxy.org/{rs["url"]}"
            
            new_rs = {
                "tag": tag,
                "type": "remote",
                "format": "binary",
                "url": download_url,
                "download_detour": "direct"
            }
            new_rule_sets.append(new_rs)
        
        config["route"]["rule_set"] = new_rule_sets

    # 4. Convert rules
    new_rules = []
    for rule in config["route"]["rules"]:
        new_rule = rule.copy()
            
        new_rules.append(new_rule)

    config["route"]["rules"] = new_rules
    
    # Fix dns rules as well?
    # The template has "dns": { "rules": [...] }
    # These also use rule_set.
    # No changes needed for DNS rules as they already use rule_set tags which we preserved.


    # Save config
    with open(output_path, 'w') as f:
        json.dump(config, f, indent=2)
    
    print(f"Config generated at {output_path}")

if __name__ == "__main__":
    main()
