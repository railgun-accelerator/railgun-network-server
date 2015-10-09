assert = require 'assert'

module.exports = class Quality
  constructor: (@delay=0, @jitter=0, @reliability=1, @cost=0)->

  @unreachable: new Quality(0,0,0,0)


  concat: (delay, jitter, reliability, cost)->
    if delay instanceof Quality
      @concat(delay.delay, delay.jitter, delay.reliability, delay.cost)
    else
      @delay += delay
      @jitter += jitter
      @reliability *= reliability
      @cost += cost
    this

  # 若 reliability = 0，metric 应为 +∞
  # 对于两条路线，同时连接任何一个相同的(reliability > 0的)线路，大小关系不变
  metric: ()->
    assert(@jitter >= 0)
    assert(0 <= @reliability <= 1)
    assert(@cost >= 0)
    if @reliability == 0
      Number.POSITIVE_INFINITY
    else
      @delay + (1 - @reliability) * 6 + @cost * 0.1
