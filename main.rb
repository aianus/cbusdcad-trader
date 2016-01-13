require 'coinbase/exchange'
require 'eventmachine'
require './lib/mailer.rb'
require './lib/exchange_rates.rb'

include Coinbase::Exchange

I18n.enforce_available_locales = false
$stdout.sync = true

class Main
  ACCEPTABLE_COMMISSION = ENV.fetch('ACCEPTABLE_COMMISSION', '0.0').to_f

  def initialize
    @from_currency = ENV.fetch('@from_currency', 'USD')
    @to_currency = ENV.fetch('@to_currency', 'CAD')
    @from_product_id = "BTC-#{@from_currency}"
    @to_product_id = "BTC-#{@to_currency}"

    @from_rest_client = Coinbase::Exchange::Client.new(ENV['FROM_COINBASE_EXCHANGE_API_KEY'],
                                                       ENV['FROM_COINBASE_EXCHANGE_API_SECRET'],
                                                       ENV['FROM_COINBASE_EXCHANGE_API_PASSWORD'],
                                                       product_id: @from_product_id)

    @to_rest_client = Coinbase::Exchange::Client.new(ENV['TO_COINBASE_EXCHANGE_API_KEY'],
                                                     ENV['TO_COINBASE_EXCHANGE_API_SECRET'],
                                                     ENV['TO_COINBASE_EXCHANGE_API_PASSWORD'],
                                                     product_id: @to_product_id)

    @from_websocket = Coinbase::Exchange::Websocket.new(product_id: @from_product_id,
                                                        keepalive: true)

    @to_websocket = Coinbase::Exchange::Websocket.new(product_id: @to_product_id,
                                                      keepalive: true)

    @from_book = LiveOrderbook.new(@from_product_id, @from_rest_client, @from_websocket)
    @to_book = LiveOrderbook.new(@to_product_id, @to_rest_client, @to_websocket)

    @current_limit_order = nil
    @pending_limit_order = false
  end

  def start_em
    EM.run do
      @from_book.on_ready do
        @to_book.on_ready(&method(:reevaluate_order))
      end

      @from_book.on_message do |_|
        self.reevaluate_order
      end

      @to_book.on_message do |_|
        self.reevaluate_order
      end

      @to_book.on_match(&method(:process_match))

      @to_rest_client.accounts do |accounts|
        @to_balance =
          Money.from_amount(
            accounts.select{|acc| acc.currency == "BTC" }.first.available,
            "BTC"
          )

        @to_book.start!
      end

      @from_book.start!
    end
  end

  def process_match(msg)
    return if !@current_limit_order

    if msg['maker_order_id'] == @current_limit_order[Orderbook::ORDER_ID]
      size = BigDecimal.new(msg['size'])
      order_id = msg['maker_order_id']

      # We got matched on the to side, do a market order on the from side
      puts "Got a match on #{order_id} for #{size}"
      @current_limit_order[Orderbook::SIZE] -= size

      @from_rest_client.bid(size, nil, type: 'market') do |resp|

        if @current_limit_order[Orderbook::SIZE] == 0
          exit 0
        end
      end
    end
  end

  def reevaluate_order
    return if @pending_limit_order || !@to_book.ready? || !@from_book.ready?

    # Move the limit order on the 'to' side to the correct position
    from_price     = Money.from_amount(@from_book.asks.first[Orderbook::PRICE], @from_currency)
    worst_to_price = (from_price.exchange_to(@to_currency) * (1 - ACCEPTABLE_COMMISSION)).to_d

    best_ask = @to_book.asks.first
    target_best_ask = best_ask[Orderbook::PRICE] - BigDecimal.new('0.01')
    target_price = [worst_to_price, target_best_ask].max

    # If there is no order yet, place one
    if !@current_limit_order
      size = (@to_balance * BigDecimal.new('0.99')).to_d
      puts "Placing limit order for #{size} @ #{target_price}"
      place_limit_order(target_price, size)
      return
    end

    current_price = @current_limit_order[Orderbook::PRICE]

    # If we are already the best ask and the price is better than worst_to_price, do nothing
    if best_ask? && current_price > worst_to_price
      return
    end

    # If we're not the best ask and the target hasn't moved much, leave it alone
    if !best_ask? &&
      target_price != target_best_ask &&
      (current_price - target_price).abs < BigDecimal.new('0.10')
      return
    end

    if target_price == current_price
      return
    end

    # Otherwise, we need to cancel the current order and place a new one in the correct place
    puts "Moving limit order to #{target_price}"
    move_limit_order(target_price)
  end

private

  def place_limit_order(price, size)
    @current_limit_order = nil
    @pending_limit_order = true
    @to_rest_client.ask(size, price, post_only: true) do |order|
      @pending_limit_order = false

      # Order accepted
      if order.id
        @current_limit_order = [price, size, order.id]
      end
    end
  end

  def move_limit_order(price)
    order_id = @current_limit_order[Orderbook::ORDER_ID]
    size     = @current_limit_order[Orderbook::SIZE]
    @pending_limit_order = true
    @to_rest_client.cancel(order_id) do |resp|
      if resp.message != 'OK'
        # There was an error canceling the order; we probably got filled
        # Wait until the match is processed and we exit
        puts "Error canceling order #{order_id} with #{resp.message}"
        return
      end

      # Successfully canceled, place the new order
      place_limit_order(price, size)
    end
  end

  def best_ask?
    best_ask = @to_book.asks.first
    @current_limit_order &&
      @current_limit_order[Orderbook::PRICE] == best_ask[Orderbook::PRICE]
  end
end

Main.new.start_em