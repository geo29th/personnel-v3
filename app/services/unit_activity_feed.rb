# Builds a paginated, reverse-chronological feed of activity within a unit's
# subtree: extended LOAs, event attendance, awards, AIT progress, promotions,
# assignments and discharges.
#
# Items are merged in SQL with UNION ALL so pagination happens in the database,
# then each page's records are loaded per type with their associations.
# Only the last WINDOW_DAYS days, including today, are included.
#
# Member-related activity (everything except events and assignments) is
# attributed to the unit if the member was assigned within its subtree on the
# date of the activity, so history stays accurate after transfers.
class UnitActivityFeed
  include Service

  PER_PAGE = 50
  WINDOW_DAYS = 30

  Item = Data.define(:type, :date, :record)

  def initialize(unit, page: 1, per_page: PER_PAGE)
    @unit_ids = unit.subtree.ids # include inactive units
    @page = [page.to_i, 1].max
    @per_page = per_page
    @window = (Date.current - (WINDOW_DAYS - 1))..Date.current
  end

  def call
    rows = connection.select_rows(<<~SQL)
      SELECT item_type, item_id, item_date FROM (#{union_sql}) activity
      ORDER BY item_date DESC, item_type, item_id DESC
      LIMIT #{@per_page.to_i} OFFSET #{(@page - 1) * @per_page.to_i}
    SQL
    total_count = connection.select_value("SELECT COUNT(*) FROM (#{union_sql}) activity")

    records = load_records(rows)
    items = rows.filter_map do |type, id, date|
      record = records.dig(type, id.to_i)
      Item.new(type: type.underscore.to_sym, date: date.to_date, record:) if record
    end

    Kaminari.paginate_array(items, total_count:, limit: @per_page, offset: (@page - 1) * @per_page)
  end

  private

  def connection = ActiveRecord::Base.connection

  def union_sql
    @union_sql ||= sources.map do |type, relation, id_sql, date_sql|
      relation
        .select("#{connection.quote(type)} AS item_type, #{id_sql} AS item_id, #{date_sql} AS item_date")
        .where("#{date_sql} BETWEEN ? AND ?", @window.begin, @window.end)
        .to_sql
    end.join(" UNION ALL ")
  end

  # [type, relation, id SQL, date SQL]
  def sources
    eloa_date = "COALESCE(DATE(eloas.posting_date), eloas.start_date)"

    [
      ["ExtendedLOA", ExtendedLOA.where(assigned_in_subtree_on("eloas", eloa_date)),
        "eloas.id", eloa_date],

      ["Event", Event.for_unit(@unit_ids).past
        .where(AttendanceRecord.where("attendance.event_id = events.id").arel.exists),
        "events.id", "DATE(events.starts_at)"],

      ["UserAward", UserAward.where(assigned_in_subtree_on("awardings", "awardings.date")),
        "awardings.id", "awardings.date"],

      # One item per member, author and day, like v2
      ["AITQualification", AITQualification
        .where(assigned_in_subtree_on("qualifications", "qualifications.date"))
        .group(:member_id, :author_member_id, :date),
        "MIN(qualifications.id)", "qualifications.date"],

      ["Promotion", Promotion.where(assigned_in_subtree_on("promotions", "promotions.date")),
        "promotions.id", "promotions.date"],

      ["Assignment", Assignment.where(unit_id: @unit_ids),
        "assignments.id", "assignments.start_date"],

      # Matches Discharge.for_unit: assignments in the subtree ended on the discharge date
      ["Discharge", Discharge.where(Assignment
        .where("assignments.member_id = discharges.member_id")
        .where("assignments.end_date = discharges.date")
        .where(unit_id: @unit_ids)
        .arel.exists),
        "discharges.id", "discharges.date"]
    ]
  end

  def assigned_in_subtree_on(table, date_sql)
    Assignment
      .where("assignments.member_id = #{table}.member_id")
      .where(unit_id: @unit_ids)
      .where("assignments.start_date <= #{date_sql}")
      .where("assignments.end_date IS NULL OR assignments.end_date >= #{date_sql}")
      .arel.exists
  end

  def load_records(rows)
    ids_by_type = rows.group_by(&:first).transform_values { |r| r.map { |row| row[1].to_i } }

    ids_by_type.to_h do |type, ids|
      [type, preloaded(type).where(id: ids).index_by(&:id)]
    end
  end

  def preloaded(type)
    case type
    when "ExtendedLOA" then ExtendedLOA.includes(user: :rank)
    when "Event" then Event.includes(:unit, :attendance_totals)
    when "UserAward" then UserAward.includes(:award, user: :rank)
    when "AITQualification" then AITQualification.includes(user: :rank, author: :rank)
    when "Promotion" then Promotion.includes(:new_rank, :old_rank, user: :rank)
    when "Assignment" then Assignment.includes(:unit, :position, user: :rank)
    when "Discharge" then Discharge.includes(user: :rank)
    end
  end
end
