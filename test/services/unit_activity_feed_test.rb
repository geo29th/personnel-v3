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
      start_date: 1.year.ago, end_date: 6.months.ago)
    create(:assignment, user: transferee, unit: @other_squad, start_date: 6.months.ago)
    before = create(:user_award, user: transferee, date: 9.months.ago)
    after = create(:user_award, user: transferee, date: 1.month.ago)

    records = UnitActivityFeed.call(@company).map(&:record)

    assert_includes records, before
    refute_includes records, after
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

  test "paginates" do
    create_list(:promotion, 3, user: @member)

    page = UnitActivityFeed.call(@company, page: 2, per_page: 2)

    assert_equal 4, page.total_count # 3 promotions + 1 assignment
    assert_equal 2, page.current_page
    assert_equal 2, page.size
  end
end
