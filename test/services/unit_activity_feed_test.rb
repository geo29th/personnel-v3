require "test_helper"

class UnitActivityFeedTest < ActiveSupport::TestCase
  setup do
    @company = create(:unit, abbr: "Able Co. HQ")
    @squad = create(:unit, parent: @company, abbr: "Able 1-1")
    @other_squad = create(:unit, abbr: "Baker 1-1")

    @member = create(:user)
    create(:assignment, user: @member, unit: @squad, start_date: 1.year.ago)
  end

  test "orders items newest first across types" do
    award = create(:user_award, user: @member, date: 3.days.ago)
    promotion = create(:promotion, user: @member, date: 1.day.ago)

    records = UnitActivityFeed.call(@company).map(&:record)

    assert_equal [promotion, award], records.first(2)
  end

  test "only includes member activity while they were assigned to the subtree" do
    transferee = create(:user)
    create(:assignment, user: transferee, unit: @squad,
      start_date: 1.year.ago, end_date: 15.days.ago)
    create(:assignment, user: transferee, unit: @other_squad, start_date: 15.days.ago)
    before = create(:user_award, user: transferee, date: 20.days.ago)
    after = create(:user_award, user: transferee, date: 5.days.ago)

    records = UnitActivityFeed.call(@company).map(&:record)

    assert_includes records, before
    refute_includes records, after
  end

  test "only includes the last 30 days, including today" do
    today = create(:promotion, user: @member, date: Date.current)
    oldest = create(:promotion, user: @member, date: Date.current - 29)
    too_old = create(:promotion, user: @member, date: Date.current - 30)
    future = create(:promotion, user: @member, date: Date.current + 1)

    records = UnitActivityFeed.call(@company).map(&:record)

    assert_includes records, today
    assert_includes records, oldest
    refute_includes records, too_old
    refute_includes records, future
  end

  test "groups AIT progress by member, author and day" do
    author = create(:user)
    create_list(:ait_qualification, 3, user: @member, author:, date: 2.days.ago)

    items = UnitActivityFeed.call(@company).select { |i| i.type == :ait_qualification }

    assert_equal 1, items.size
  end

  test "only includes events with attendance recorded" do
    reported = create(:event, unit: @squad, starts_at: 1.week.ago)
    create(:attendance_record, user: @member, event: reported, attended: true)
    unreported = create(:event, unit: @squad, starts_at: 2.weeks.ago)

    records = UnitActivityFeed.call(@company).map(&:record)

    assert_includes records, reported
    refute_includes records, unreported
  end

  test "dates events in their own time zone, across a daylight saving change" do
    eastern = ActiveSupport::TimeZone["Eastern Time (US & Canada)"]
    pacific = ActiveSupport::TimeZone["Pacific Time (US & Canada)"]

    travel_to eastern.local(2026, 11, 3, 12) do
      # Each starts on the next day in UTC
      before_change = create(:event, unit: @squad, time_zone: eastern.name,
        starts_at: eastern.local(2026, 10, 31, 21)) # EDT
      after_change = create(:event, unit: @squad, time_zone: eastern.name,
        starts_at: eastern.local(2026, 11, 2, 20)) # EST
      west_coast = create(:event, unit: @squad, time_zone: pacific.name,
        starts_at: pacific.local(2026, 11, 1, 19)) # PST
      [before_change, after_change, west_coast].each do |event|
        create(:attendance_record, user: @member, event:, attended: true)
      end

      dates = UnitActivityFeed.call(@company)
        .select { |item| item.type == :event }
        .to_h { |item| [item.record, item.date] }

      assert_equal Date.new(2026, 10, 31), dates[before_change]
      assert_equal Date.new(2026, 11, 2), dates[after_change]
      assert_equal Date.new(2026, 11, 1), dates[west_coast]
    end
  end

  test "paginates" do
    create_list(:promotion, 3, user: @member)

    page = UnitActivityFeed.call(@company, page: 2, per_page: 2)

    assert_equal 3, page.total_count # the assignment started a year ago
    assert_equal 2, page.current_page
    assert_equal 1, page.size
  end
end
