dgram = require 'dgram'
assert = require 'assert'
http = require 'http'

Quality = require './quality'

server_port = 495
timeout = 10

regions = [
  {id: 0, name: "default"},
  {id: 1, name: "ap"},
  {id: 2, name: "cn"}
]

gateways = {
  2: {
    2: {server_id: 2, region_id: 2, delay: 0, jitter: 0, reliability: 1}
  },
  3: {
    0: {server_id: 3, region_id: 0, delay: 0.1, jitter: 0, reliability: 1},
    1: {server_id: 3, region_id: 1, delay: 0, jitter: 0, reliability: 1}
  },
  4: {
    0: {server_id: 4, region_id: 0, delay: 0, jitter: 0, reliability: 1}
  },
  6: {
    2: {server_id: 6, region_id: 2, delay: 0, jitter: 0, reliability: 1}
  },
  7: {
    0: {server_id: 7, region_id: 0, delay: 0.1, jitter: 0, reliability: 1},
    1: {server_id: 7, region_id: 1, delay: 0, jitter: 0, reliability: 1}
  }
}

servers = {
  2: {id: 2, inbound_cost: 0, outbound_cost: 0.8},
  3: {id: 3, inbound_cost: 0, outbound_cost: 0.05},
  4: {id: 4, inbound_cost: 0, outbound_cost: 0.03},
  6: {id: 6, inbound_cost: 0, outbound_cost: 0.8},
  7: {id: 7, inbound_cost: 0, outbound_cost: 1},
}

sequence = 0
updating = null
timeout_timer = null

socket = dgram.createSocket('udp4')

route_quality = (from, to, next_hop = servers[from].next_hop[to])->
  assert next_hop?
  assert from != next_hop
  assert from != to

  result = new Quality()

  current = from
  next = next_hop
  route = [current, next]

  while true
    quality = servers[next].quality[current]
    return Quality.unreachable if !quality or quality.reliability <= 0 # 网络不通，视为黑洞
    result.concat(quality.delay, quality.jitter, quality.reliability, servers[current].outbound_cost + servers[next].inbound_cost)
    return result if next == to # 到达

    # 寻找下一跳
    current = next
    next = servers[current].next_hop[to]
    assert next #to server_id 型路由，由于 server 两两相连，下一跳一定是存在的，最坏情况也是直达
    if next in route # 环路
      return Quality.unreachable
    else
      route.push next

route_metric = (from, to, next_hop)->
  route_quality(from, to, next_hop).metric()

gateway_metric = (from, to, gateway)->
  quality = gateways[gateway][to]
  assert quality
  result = new Quality(quality.delay, quality.jitter, quality.reliability, servers[gateway].outbound_cost + servers[gateway].inbound_cost)
  if from != gateway
    result.concat route_quality(from, gateway)
    result.concat route_quality(gateway, from)
  result.metric()

update_route = (server, to)->
  # 计算当前和最优路线
  if to.name? # is region
    type = 'gateway'
    current_route = server[type][to.id]
    if current_route
      current_metric = gateway_metric(server.id, to.id, current_route)
    else
      current_metric = Number.POSITIVE_INFINITY
    best_route = current_route
    best_metric = current_metric
    for index, route_server of servers when route_server.id != current_route and gateways[route_server.id]? and gateways[route_server.id][to.id]
      metric = gateway_metric(server.id, to.id, route_server.id)
      if metric < best_metric
        best_route = route_server.id
        best_metric = metric
  else
    assert(to.inbound_cost?) # is server
    type = 'next_hop'
    current_route = server[type][to.id]
    assert(current_route) # 对于 to server 型路由，下一跳一定是存在的
    current_metric = route_metric(server.id, to.id, current_route)
    best_route = current_route
    best_metric = current_metric
    for index, route_server of servers when route_server.id != current_route and route_server.id != server.id # 对于 to server型路由，下一跳是自己是没有意义的
      metric = route_metric(server.id, to.id, route_server.id)
      if metric < best_metric
        best_route = route_server.id
        best_metric = metric

  # 决定是否变更

  now = new Date().getTime() / 1000
  if current_route != best_route and (current_metric is Number.POSITIVE_INFINITY or (current_metric - best_metric - 0.01) * (now - server[type+'_updated_at'][to.id]) > 10)
    console.log server[type+'_updated_at'][to.id],server[type+'_updated_at'], to.id
    console.log "update ##{sequence}: #{type} server #{server.id} to #{to.id}: #{current_route}(#{current_metric}) -> #{best_route}(#{best_metric}) age #{now - server[type+'_updated_at'][to.id]}"
    server[type][to.id] = best_route
    server[type+'_updated_at'][to.id] = now
    updating = setInterval ->
      send_route server, to.id, best_route, type
    , 1000
    send_route server, to.id, best_route, type
    timeout_timer = setTimeout ->
      delete server.address
      delete server.port
      clearInterval(updating)
      updating = null
      console.log "server#{server.id} lost connection."
    ,  timeout * 1000
    return true

  false

send_route = (server, to, route, type)->
  message = {sequence: sequence, to: to}
  message[type] = route
  message = JSON.stringify message
  socket.send message, 0, message.length, server.port, server.address
reset_route = (server)->
  now = new Date().getTime() / 1000
  server.quality = {}
  server.next_hop = {}
  server.next_hop_updated_at = {}
  server.gateway = {}
  server.gateway_updated_at = {}
  for i,s of servers
    server.next_hop[s.id] = s.id
    server.next_hop_updated_at[s.id] = now
  for region_id, region of regions when gateways[server.id]? and gateways[server.id][region_id]?
    server.gateway[region_id] = server.id
    server.gateway_updated_at[region_id] = now

socket.on 'message', (message, rinfo) ->

  message = JSON.parse(message)
  server = servers[message.server_id]
  return unless server?

  if server.address != rinfo.address or server.port != rinfo.port # 重置 server 状态
    server.address = rinfo.address
    server.port = rinfo.port
    console.log "server #{server.id} connected from #{server.address}:#{server.port}"
    reset_route(server)

  server.quality = message.quality

  #console.log updating
  if updating? and message.acknowledgement == sequence
    #console.log "ack ##{sequence}: server#{server.id}"
    clearInterval(updating)
    clearTimeout(timeout_timer)
    updating = null
    sequence += 1

  if !updating?
    for i, server of servers when server.address?
      for j, to_server of servers when server.id != to_server.id
        return if update_route(server, to_server)
      for j, to_region of regions
        return if update_route(server, to_region)

for server_id, server of servers
  reset_route(server)

socket.bind server_port

http.createServer (req, res)->
  res.writeHead 200, 'Content-Type': 'application/json'
  res.end JSON.stringify(servers)
.listen server_port