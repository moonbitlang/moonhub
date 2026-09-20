# The recovery surface is the repository's Web/SSH and optional DinD topology.
# Inspect is authoritative: the checkout and image tags may already be newer.
def role: .Config.Labels["com.docker.compose.service"];
def volume_key($service; $target):
  if $target == "/data" and (["web", "ssh"] | index($service)) then "data"
  elif $target == "/var/lib/moonhub/ssh" and $service == "ssh" then "ssh-host-keys"
  elif $target == "/run/moonhub-docker" then "pipeline-socket"
  elif $target == "/var/lib/moonhub/provider" then "pipeline-control"
  elif $target == "/var/lib/docker" and $service == "pipeline-docker" then "pipeline-docker-data"
  else error("Unsupported volume destination: " + $service + ":" + $target) end;
def binding_allowed($service; $target):
  ($service == "web" and (["/run/secrets/root_password", "/run/secrets/ssh-import"] | index($target)) != null)
  or ($service == "pipeline-provider" and $target == "/run/secrets/provider_token");
def mounts:
  . as $container | role as $service |
  [.Mounts | to_entries[] | .key as $index | .value |
    if .Type == "volume" then
      {type: "volume", source: volume_key($service; .Destination), target: .Destination, read_only: (.RW | not)}
    elif .Type == "bind" and binding_allowed($service; .Destination) then
      {type: "bind", source: ("./bindings/" + $service + "-" + ($index | tostring)), target: .Destination, read_only: true}
    else error("Unsupported mount: " + $service + ":" + .Destination) end];
def environment:
  [.Config.Env[] | if startswith("MOONHUB_RUNNER_IMAGE=") and $runner != "" then
    "MOONHUB_RUNNER_IMAGE=" + $runner else . end];
def service:
  {image: .Image, entrypoint: .Config.Entrypoint, command: .Config.Cmd,
   environment: environment, user: .Config.User, working_dir: .Config.WorkingDir,
   restart: .HostConfig.RestartPolicy.Name, privileged: .HostConfig.Privileged,
   read_only: .HostConfig.ReadonlyRootfs, init: (.HostConfig.Init // false),
   cap_add: .HostConfig.CapAdd, cap_drop: .HostConfig.CapDrop,
   security_opt: .HostConfig.SecurityOpt, volumes: mounts,
   stop_grace_period: ((.Config.StopTimeout // 30 | tostring) + "s"),
   ports: [(.HostConfig.PortBindings // {}) | to_entries[] | .key as $port | .value[] |
     {target: ($port | split("/")[0] | tonumber), published: .HostPort, host_ip: .HostIp,
      protocol: ($port | split("/")[1])}],
   networks: (.NetworkSettings.Networks | to_entries | map(
     .key as $name | ($networks[0][] | select(.Name == $name) | .Labels["com.docker.compose.network"]) as $key |
     if $key != "default" and $key != "pipeline" then error("Unsupported network: " + $name) else
       {key: $key, value: (if (.value.IPAMConfig.IPv4Address // "") != "" then
         {ipv4_address: .value.IPAMConfig.IPv4Address} else {} end)} end) | from_entries)}
  + (if .Config.Healthcheck then {healthcheck: {
      test: .Config.Healthcheck.Test,
      interval: ((.Config.Healthcheck.Interval // 0 | tostring) + "ns"),
      timeout: ((.Config.Healthcheck.Timeout // 0 | tostring) + "ns"),
      start_period: ((.Config.Healthcheck.StartPeriod // 0 | tostring) + "ns"),
      retries: (.Config.Healthcheck.Retries // 0)}} else {} end)
  | with_entries(select(.value != null));

if (map(role) | sort) != ["ssh", "web"] and
   (map(role) | sort) != ["pipeline-docker", "pipeline-provider", "ssh", "web"] then
  error("Recovery requires exactly Web/SSH and optionally both pipeline services")
elif ([.[] | select(role == "web" or role == "ssh") | .Mounts[] | select(.Destination == "/data") | .Name] | unique | length) != 1 then
  error("Web/SSH must share one data volume")
else
  {services: (map({key: role, value: service}) | from_entries),
   volumes: ([.[] | mounts[] | select(.type == "volume") | {key: .source, value: {}}] | from_entries),
   networks: ($networks[0] | map({key: .Labels["com.docker.compose.network"], value:
     (if .Labels["com.docker.compose.network"] == "pipeline" then
       {name: .Name, ipam: {config: .IPAM.Config}} else {} end)}) | from_entries)}
  | .services.ssh.depends_on = {web: {condition: "service_healthy"}}
  | if .services["pipeline-provider"] then
      .services["pipeline-provider"].depends_on = {
        web: {condition: "service_healthy"}, "pipeline-docker": {condition: "service_healthy"}}
    else . end
  # Compose interpolates dollars even in JSON strings. Snapshot literal values.
  | walk(if type == "string" then gsub("\\$"; "$$") else . end)
end
