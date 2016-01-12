require './lib/orderbook.rb'

class LiveOrderbook
  attr_accessor :sequence

  def initialize(product_id, rest_client = nil, websocket = nil)
    @product_id = product_id
    @websocket = websocket
    @rest_client = rest_client

    @websocket.message do |msg|
      process_message(msg)
    end

    @queue = Queue.new

    @on_message_cb =
      @on_open_cb =
      @on_done_cb =
      @on_match_cb =
      @on_change_cb = lambda { |msg| nil }

    @on_ready_cb = lambda { nil }
  end

  def start!
    @websocket.start!
    EM.add_timer 5, self.method(:refresh!)
  end

  def on_ready(&block)
    @on_ready_cb = block
  end

  def on_message(&block)
    @on_message_cb = block
  end

  def on_open(&block)
    @on_open_cb = block
  end

  def on_done(&block)
    @on_done_cb = block
  end

  def on_change(&block)
    @on_change_cb = block
  end

  def on_match(&block)
    @on_match_cb = block
  end

  def process_message(msg)
    if !ready?
      @queue << msg
    elsif msg['sequence'] > @sequence + 1
      refresh!
    elsif msg['sequence'] == @sequence + 1
      case msg['type']
      when "open"
        @orderbook.open(msg)
        @on_open_cb.call(msg)
      when "done"
        @orderbook.done(msg)
        @on_done_cb.call(msg)
      when "change"
        @orderbook.change(msg)
        @on_change_cb.call(msg)
      when "match"
        @on_match_cb.call(msg)
      end

      @sequence = msg['sequence'].to_i

      @on_message_cb.call(msg)
    end
  end

  def refresh!
    puts "Refreshing orderbook from snapshot!"

    @orderbook = nil
    @rest_client.orderbook(product_id: @product_id, level: 3) do |resp|
      @orderbook = Orderbook.new(resp)
      @sequence = resp['sequence'].to_i

      while !@queue.empty?
        process_message(@queue.pop)
      end

      @on_ready_cb.call
    end
  end

  def ready?
    !@orderbook.nil?
  end

  def bids
    @orderbook.bids
  end

  def asks
    @orderbook.asks
  end
end
