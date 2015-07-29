dgram = require 'dgram'
assert = require 'assert'
http = require 'http'

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

caculate_metric = (delay, jitter, reliability, cost)->
  assert(jitter >= 0)
  assert(0 <= reliability <= 1, "reliability: #{reliability}")
  assert(cost >= 0)

  delay + (1 - reliability) * 6 + cost * 0.1

route_metric = (server_id, from, to, next_hop)->

  #console.log "route_metric(#{server_id}, #{from}, #{to}, #{next_hop})"


  # delay 由于涉及时差问题，对内、对外、补偿权重必须是一致的。
  # 其他几个变量对内、对外权重可以不一致。

  delay = 0
  internal_reliability = 1
  internal_jitter = 0
  internal_cost = 0

  external_reliability = 1
  external_jitter = 0
  external_cost = 0

  current = server_id
  next = next_hop
  route = [current, next]

  # 正向路由
  while true
    if next == 0 # from server_id to region_id 型路由到达出口
      assert(from != 0)
      quality = gateways[current][to]
      return Number.POSITIVE_INFINITY if !quality or quality.reliability <= 0 # 网络不通，视为黑洞
      #console.log '-gateway-', current, to, quality
      delay += quality.delay
      external_reliability *= Math.sqrt(quality.reliability)
      external_jitter += quality.jitter / 2
      external_cost += servers[current].outbound_cost
      internal_reliability *= Math.sqrt(quality.reliability)
      internal_jitter += quality.jitter / 2
      internal_cost += servers[current].inbound_cost
      if current == from # 出口直达
        return caculate_metric(delay, internal_jitter + external_jitter, internal_reliability * external_reliability, internal_cost + external_cost)
      next = servers[current].routes[0][from]
      route = [current, next]
      while true # 计算返程路线
        # 计算网络质量
        quality = servers[next].quality[current]
        return Number.POSITIVE_INFINITY if !quality or quality.reliability <= 0 # 网络不通，视为黑洞
        #console.log '-2-', current, next, quality
        delay += quality.delay
        internal_jitter += quality.jitter
        internal_reliability *= quality.reliability
        internal_cost += servers[current].outbound_cost + servers[next].inbound_cost
        # 寻找下一跳
        if next == from # 往返路径结束
          return caculate_metric(delay, internal_jitter + external_jitter, internal_reliability * external_reliability, internal_cost + external_cost)
        else
          current = next
          next = servers[current].routes[0][from]
          assert(next?) # 返程的目标是server，相当于 from all to server_id 型路由，由于 server 两两相连，下一跳一定是存在的，最坏情况也是直达
          if next in route # 环路
            return Number.POSITIVE_INFINITY
          else
            route.push next
    else
      # 计算网络质量
      quality = servers[next].quality[current]
      return Number.POSITIVE_INFINITY if !quality or quality.reliability <= 0 # 网络不通，视为黑洞
      #console.log '-3-', current, next, quality
      delay += quality.delay

      if from == 0 # 对内
        internal_reliability *= quality.reliability
        internal_jitter += quality.jitter
        internal_cost += servers[current].outbound_cost + servers[next].inbound_cost
        if next == to
          return caculate_metric(delay, internal_jitter + external_jitter, internal_reliability * external_reliability, internal_cost + external_cost)
      else
        external_reliability *= quality.reliability
        external_jitter += quality.jitter
        external_cost += servers[current].outbound_cost + servers[next].inbound_cost

      # 寻找下一跳
      current = next
      next = servers[current].routes[from][to]
      if next?
        if next in route # 环路
          return Number.POSITIVE_INFINITY
        else
          route.push next
      else
        assert(from != 0) # from all to server_id 型路由，由于 server 两两相连，下一跳一定是存在的，最坏情况也是直达
        return Number.POSITIVE_INFINITY # 对于from server_id to region 型路由，如果下一跳不存在，意味着出口没有已知路线可达，是黑洞


  # 返程 (下行) 路由
  #console.log '-2-', next


update_route = (server, from, to)->
  current_next_hop = server.routes[from][to]

  # 计算当前路线
  if current_next_hop?
    current_metric = route_metric(server.id, from, to, current_next_hop)
  else
    assert(from != 0) # from all to server_id 型路由，由于 server 两两相连，下一跳一定是存在的，最坏情况也是直达
    current_metric = Number.POSITIVE_INFINITY # 对于from server_id to region 型路由，如果下一跳不存在，意味着出口没有已知路线可达，是黑洞

  # 计算更优路线
  best_next_hop = current_next_hop
  best_metric = current_metric

  for index, next_hop_server of servers when next_hop_server.id != current_next_hop and next_hop_server != server and next_hop_server.id != from
    #console.log parseInt(next_hop), server.id
    #console.log next_hop,current_next_hop
    metric = route_metric(server.id, from, to, next_hop_server.id)
    if metric < best_metric
      best_next_hop = next_hop_server.id
      best_metric = metric
  if from != 0
    metric = route_metric(server.id, from, to, 0)
    if metric < best_metric
      best_next_hop = 0
      best_metric = metric

  now = new Date().getTime() / 1000
  if current_next_hop != best_next_hop and (current_metric is Number.POSITIVE_INFINITY or (current_metric - best_metric - 0.01) * (now - server.updated_at[from][to]) > 10)
    console.log "update ##{sequence}: server#{server.id} from #{from} to #{to} next hop #{current_next_hop}(#{current_metric}) -> #{best_next_hop}(#{best_metric})"
    server.routes[from][to] = best_next_hop
    server.updated_at[from][to] = now
    updating = setInterval ->
      send_route(server, from, to, best_next_hop)
    , 1000
    send_route(server, from, to, best_next_hop)
    timeout_timer = setTimeout ->
      delete server.address
      delete server.port
      clearInterval(updating)
      updating = null
      console.log "server#{server.id} lost connection."
    ,  timeout * 1000
    return true

  false
send_route = (server, from, to, next_hop)->
  message = {sequence: sequence, from: from, to: to, next_hop: next_hop}
  if server == from
    gateway = server
    while next_hop != 0
      gateway = next_hop
      next_hop = servers[gateway].routes[from][to]
    message.gateway = gateway
  message = JSON.stringify message
  socket.send message, 0, message.length, server.port, server.address
reset_route = (server)->
  now = new Date().getTime() / 1000
  server.quality = {}
  # 目标地址是 server 的 from all to server_id 型路由, routes[0][server_id], 对于直连目标节点的，next_hop = server_id
  # 目标地址是 region 的 from server_id to region_id 型路由, routes[server_id][region_id], 对于直连出口的，next_hop = 0
  server.routes = {}
  server.updated_at = {}
  server.routes[0] = {}
  server.updated_at[0] = {}
  for i,s of servers
    server.routes[0][i] = parseInt(i)
    server.updated_at[0][i] = now
    server.routes[i] = {}
    server.updated_at[i] = {}
    for region_id, region of regions when gateways[server.id]? and gateways[server.id][region_id]?
      server.routes[i][region_id] = 0
      server.updated_at[i][region_id] = now

socket.on 'message', (message, rinfo) ->

  message = JSON.parse(message)
  #console.log message
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
    for server_id, server of servers when server.address?
      for to of servers when to != server_id
        return if update_route(server, 0, parseInt(to))
      for from of servers
        for region in regions
          return if update_route(server, parseInt(from), region.id)

for server_id, server of servers
  reset_route(server)

socket.bind server_port

http.createServer (req, res)->
  res.writeHead 200, 'Content-Type': 'application/json'
  res.end JSON.stringify(servers)
.listen server_port