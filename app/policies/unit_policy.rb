class UnitPolicy < ApplicationPolicy
  def index?
    true
  end

  def show?
    true
  end

  # Members of the unit's subtree and leaders of units above it
  def activity?
    return false unless user
    user.has_permission?("admin") ||
      user.active_assignment_unit_path_ids.include?(record.id) ||
      user.active_assignments.where(unit_id: record.ancestor_ids).exists?
  end

  def attendance?
    user&.member?
  end

  def awols?
    user&.member?
  end

  def missing_awards?
    user&.has_permission_on_unit?("awarding_add", record) ||
      user&.has_permission?("admin")
  end

  def stats?
    user&.member?
  end

  def recruits?
    user&.member?
  end

  def discharges?
    user&.member?
  end

  def new?
    user&.has_permission?("unit_add") ||
      user&.has_permission?("admin")
  end

  def create?
    new?
  end

  def update?
    new?
  end

  def destroy?
    user&.has_permission?("admin")
  end

  def graduate?
    user&.has_permission?("admin")
  end
end
