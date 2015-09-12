# encoding: utf-8
#
class Order < ActiveRecord::Base
  attr_accessor :ignore_warnings

  # Associations
  has_many :order_articles, :dependent => :destroy
  has_many :articles, :through => :order_articles
  has_many :group_orders, :dependent => :destroy
  has_many :ordergroups, :through => :group_orders
  has_many :users_ordered, :through => :ordergroups, :source => :users
  has_one :invoice
  has_many :comments, -> { order('created_at') }, :class_name => "OrderComment"
  has_many :stock_changes
  belongs_to :supplier
  belongs_to :updated_by, :class_name => 'User', :foreign_key => 'updated_by_user_id'
  belongs_to :created_by, :class_name => 'User', :foreign_key => 'created_by_user_id'

  # Validations
  validate :ends_after_starts, :include_articles
  validate :keep_ordered_articles

  # Callbacks
  after_save :save_order_articles, :update_price_of_group_orders

  # Scopes
  scope :stockit, -> { where(supplier_id: 0).order('ends DESC') }
  scope :recent, -> { order('starts DESC').limit(10) }
  # @return [Array<Order>] Orders that are open for members to order
  # @see #open?
  scope :open, ->{ opened }

  # State machine
  include AASM
  include AASMBeforeAfter
  aasm column: :state do
    state :opened, initial: true
    state :closed
    state :finished
    state :foo

    event :close do
      transitions from: :opened, to: :closed
      after { self.ends = Time.now }
      after :update_whom
      after :perform_close
      after :send_close_mails
    end
    event :finish do
      transitions from: :closed, to: :finished
      after :update_whom
      after :perform_finish
      after :update_profit
    end
    event :finish_direct do
      transitions from: :closed, to: :finished
      after :update_whom
      after :update_profit
      after :add_finish_direct_message
    end
  end

  # Allow separate inputs for date and time
  #   with workaround for https://github.com/einzige/date_time_attribute/issues/14
  include DateTimeAttributeValidate
  date_time_attribute :starts, :ends

  def stockit?
    supplier_id == 0
  end

  # Return whether this order is open to members
  #
  # This is a separate method from the state-machine to be able to have
  # multiple states in which members can order. E.g. for a 'reduce shortages'
  # state.
  # @see #open
  # @return [Boolean] Whether this order is open to members for ordering
  def open?
    opened?
  end

  def name
    stockit? ? I18n.t('orders.model.stock') : supplier.name
  end

  def articles_for_ordering
    if stockit?
      # make sure to include those articles which are no longer available
      # but which have already been ordered in this stock order
      StockArticle.available.includes(:article_category).
        order('article_categories.name', 'articles.name').reject{ |a|
        a.quantity_available <= 0 && !a.ordered_in_order?(self)
      }.group_by { |a| a.article_category.name }
    else
      supplier.articles.available.group_by { |a| a.article_category.name }
    end
  end

  def supplier_articles
    if stockit?
      StockArticle.undeleted.reorder('articles.name')
    else
      supplier.articles.undeleted.reorder('articles.name')
    end
  end

  # Save ids, and create/delete order_articles after successfully saved the order
  def article_ids=(ids)
    @article_ids = ids
  end

  def article_ids
    @article_ids ||= order_articles.map { |a| a.article_id.to_s }
  end

  # Returns an array of article ids that lead to a validation error.
  def erroneous_article_ids
    @erroneous_article_ids ||= []
  end

  def expired?
    !ends.nil? && ends < Time.now
  end

  # sets up first guess of dates when initializing a new object
  # I guess `def initialize` would work, but it's tricky http://stackoverflow.com/questions/1186400
  def init_dates
    self.starts ||= Time.now
    if FoodsoftConfig[:order_schedule]
      # try to be smart when picking a reference day
      last = (DateTime.parse(FoodsoftConfig[:order_schedule][:initial]) rescue nil)
      last ||= Order.finished_or_after.reorder(:starts).first.try(:starts)
      last ||= self.starts
      # adjust end date
      self.ends ||= FoodsoftDateUtil.next_occurrence last, self.starts, FoodsoftConfig[:order_schedule][:ends]
    end
    self
  end

  # search GroupOrder of given Ordergroup
  def group_order(ordergroup)
    group_orders.where(:ordergroup_id => ordergroup.id).first
  end

  # Returns OrderArticles in a nested Array, grouped by category and ordered by article name.
  # The array has the following form:
  # e.g: [["drugs",[teethpaste, toiletpaper]], ["fruits" => [apple, banana, lemon]]]
  def articles_grouped_by_category
    @articles_grouped_by_category ||= order_articles.
        includes([:article_price, :group_order_articles, :article => :article_category]).
        order('articles.name').
        group_by { |a| a.article.article_category.name }.
        sort { |a, b| a[0] <=> b[0] }
  end

  def articles_sort_by_category
    order_articles.includes(:article).order('articles.name').sort do |a,b|
      a.article.article_category.name <=> b.article.article_category.name
    end
  end

  # Returns the defecit/benefit for the foodcoop
  # Requires a valid invoice, belonging to this order
  #FIXME: Consider order.foodcoop_result
  def profit(options = {})
    markup = options[:without_markup] || false
    if invoice
      groups_sum = markup ? sum(:groups_without_markup) : sum(:groups)
      groups_sum - invoice.net_amount
    end
  end

  # Returns the all round price of a finished order
  # :groups returns the sum of all GroupOrders
  # :clear returns the price without tax, deposit and markup
  # :gross includes tax and deposit. this amount should be equal to suppliers bill
  # :fc, guess what...
  def sum(type = :gross)
    total = 0
    if type == :net || type == :gross || type == :fc
      for oa in order_articles.ordered.includes(:article, :article_price)
        quantity = oa.units * oa.price.unit_quantity
        case type
          when :net
            total += quantity * oa.price.price
          when :gross
            total += quantity * oa.price.gross_price
          when :fc
            total += quantity * oa.price.fc_price
        end
      end
    elsif type == :groups || type == :groups_without_markup
      for go in group_orders.includes(group_order_articles: {order_article: [:article, :article_price]})
        for goa in go.group_order_articles
          case type
            when :groups
              total += goa.result * goa.order_article.price.fc_price
            when :groups_without_markup
              total += goa.result * goa.order_article.price.gross_price
          end
        end
      end
    end
    total
  end

  protected

  def ends_after_starts
    return unless ends && starts
    errors.add(:ends, I18n.t('orders.model.error_starts_before_ends')) if ends < starts
  end

  def include_articles
    errors.add(:articles, I18n.t('orders.model.error_nosel')) if article_ids.empty?
  end

  def keep_ordered_articles
    chosen_order_articles = order_articles.where(article_id: article_ids)
    to_be_removed = order_articles - chosen_order_articles
    to_be_removed_but_ordered = to_be_removed.select { |a| a.quantity > 0 || a.tolerance > 0 }
    unless to_be_removed_but_ordered.empty? || ignore_warnings
      errors.add(:articles, I18n.t(stockit? ? 'orders.model.warning_ordered_stock' : 'orders.model.warning_ordered'))
      @erroneous_article_ids = to_be_removed_but_ordered.map { |a| a.article_id }
    end
  end

  def save_order_articles
    # fetch selected articles
    articles_list = Article.find(article_ids)
    # create new order_articles
    (articles_list - articles).each { |article| order_articles.create(:article => article) }
    # delete old order_articles
    articles.reject { |article| articles_list.include?(article) }.each do |article|
      order_articles.detect { |order_article| order_article.article_id == article.id }.destroy
    end
  end

  private

  def update_whom(*args, user: nil)
    self.updated_by = user if user
  end

  def perform_close
    # Update order_articles. Save the current article_price to keep price consistency
    # Also save results for each group_order_result
    order_articles.includes(:article, :group_order_articles).find_each do |oa|
      oa.update_attribute(:article_price, oa.article.article_prices.first)
      oa.group_order_articles.each do |goa|
        goa.save_results!
        # Delete no longer required order-history (group_order_article_quantities) and
        # TODO: Do we need articles, which aren't ordered? (units_to_order == 0 ?)
        #    A: Yes, we do - for redistributing articles when the number of articles
        #       delivered changes, and for statistics on popular articles. Records
        #       with both tolerance and quantity zero can be deleted.
        #goa.group_order_article_quantities.clear
      end
    end

    # Update GroupOrder prices
    group_orders.each(&:update_price!)

    # Stats
    ordergroups.each(&:update_stats!)
  end

  def send_close_mails
    Resque.enqueue(UserNotifier, FoodsoftConfig.scope, 'closed_order', id)
  end

  def perform_finish
    transaction_note = I18n.t('orders.model.notice_close',
      name: name, ends: ends.strftime(I18n.t('date.formats.default')))

    gos = group_orders.includes(:ordergroup) # Fetch group_orders
    gos.each(&:update_price!)                # Update prices of group_orders

    # Start updating account balances
    gos.each do |group_order|
      price = -group_order.price                   # decrease! account balance
      group_order.ordergroup.add_financial_transaction!(price, transaction_note, finished_by)
    end

    if stockit?                              # Decreases the quantity of stock_articles
      for oa in order_articles.includes(:article)
        oa.update_results!                         # Update units_to_order of order_article
        stock_changes.create! stock_article: oa.article, quantity: -oa.units_to_order
      end
    end
  end

  def update_profit
    self.foodcoop_result = profit
  end

  # Updates the "price" attribute of GroupOrders or GroupOrderResults
  # This will be either the maximum value of a current order or the actual order value of a finished order.
  def update_price_of_group_orders
    group_orders.each { |group_order| group_order.update_price! }
  end

  def add_finish_direct_message(*args, user: nil)
    comments.create user: user, text: I18n.t('orders.model.close_direct_message')
  end
end
