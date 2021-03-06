# encoding: UTF-8
# frozen_string_literal: true

class Deposit < ActiveRecord::Base
  extend ActiveModel::Translation
  STATES = %i[submitted canceled rejected accepted collected received ].freeze

  include AASM
  include AASM::Locking
  include BelongsToCurrency
  include BelongsToMember
  include TIDIdentifiable
  include FeeChargeable

  acts_as_eventable prefix: 'deposit', on: %i[create update]

  validates :tid, :aasm_state, :type, presence: true
  validates :completed_at, presence: { if: :completed? }
  validates :block_number, allow_blank: true, numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :amount,
            numericality: {
              greater_than_or_equal_to:
                -> (deposit){ deposit.currency.min_deposit_amount }
            }

  scope :recent, -> { order(id: :desc) }
  scope :escrow, -> { joins(:currency)
                        .where( 'currencies.type' => :fiat )
                        .where( 'currencies.id' => ENV.fetch('API_XRAY_CURRENCIES','')&.split(',') )
                    }

  before_validation { self.completed_at ||= Time.current if completed? }

  aasm whiny_transitions: false do
    state :submitted, initial: true
    state :canceled
    state :rejected
    state :accepted
    state :skipped
    state :collected
    state :received
    event(:cancel) { transitions from: :submitted, to: :canceled }
    event(:reject) { transitions from: :submitted, to: :rejected }
    event(:receive) { transitions from: :submitted, to: :received }
    event :accept do
      transitions from: %i[submitted received], to: :accepted
      after :process_funds
      after :send_relevant_mail
    end
    event :skip do
      transitions from: :accepted, to: :skipped
    end
    event :dispatch do
      transitions from: %i[accepted skipped], to: :collected
    end
  end

  def account
    member&.ac(currency)
  end

  def escrow?
    currency.escrow?
  end

  def sn
    member&.sn
  end

  def sn=(sn)
    self.member = Member.find_by_sn(sn)
  end

  def as_json_for_event_api
    { tid:                      tid,
      uid:                      member.uid,
      currency:                 currency_id,
      amount:                   amount.to_s('F'),
      state:                    aasm_state,
      created_at:               created_at.iso8601,
      updated_at:               updated_at.iso8601,
      completed_at:             completed_at&.iso8601,
      blockchain_address:       address,
      blockchain_txid:          txid }
  end

  def completed?
    !submitted?
  end

  def process_funds
    if !currency.escrow?
      account.plus_funds(amount)
    else
      account.member.accounts.find_by(currency_id: :afcash).plus_funds(amount)
    end
  end

  def send_relevant_mail
    if !currency.escrow?
      send_mail
    else
      send_release_mail
    end
  end

  def plus_funds
    account.plus_funds(amount)
  end

  def collect!
    if coin?
      if currency.is_erc20?
        AMQPQueue.enqueue(:deposit_collection_fees, id: id)
      else
        AMQPQueue.enqueue(:deposit_collection, id: id)
      end
    else
      if currency.escrow?
        Rails.logger.info { "Skipping escrow subtype currency collection" }
      else
        AMQPQueue.enqueue(:deposit_fiat, id: id)
      end
    end
  end

  def send_mail
    DepositMailer.accepted(self.id).deliver if self.accepted?
  end

  def send_release_mail
    DepositMailer.escrow_released(self.id).deliver if self.accepted?
  end

  def self.fiat_code
    #to be made a modal function in the future. 
    {
      "ngn": 566,
      "usd": 840,
      "eur": 978,
      "gbp": 826,
    }
  end
end

# == Schema Information
# Schema version: 20190912132009
#
# Table name: deposits
#
#  id           :integer          not null, primary key
#  member_id    :integer          not null
#  currency_id  :string(10)       not null
#  amount       :decimal(32, 16)  not null
#  fee          :decimal(32, 16)  not null
#  address      :string(95)
#  txid         :string(128)
#  txout        :integer
#  aasm_state   :string(30)       not null
#  block_number :integer
#  type         :string(30)       not null
#  tid          :string(64)       not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  completed_at :datetime
#  comment      :string(255)
#
# Indexes
#
#  index_deposits_on_aasm_state_and_member_id_and_currency_id  (aasm_state,member_id,currency_id)
#  index_deposits_on_currency_id                               (currency_id)
#  index_deposits_on_currency_id_and_txid_and_txout            (currency_id,txid,txout) UNIQUE
#  index_deposits_on_member_id_and_txid                        (member_id,txid)
#  index_deposits_on_tid                                       (tid)
#  index_deposits_on_type                                      (type)
#
