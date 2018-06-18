# The abstract base class that defines common behavior for all types of
# criterion.
class Criterion < ApplicationRecord
  after_update :scale_marks

  has_many :criteria_assignment_files_joins,
           as: :criterion,
           dependent: :destroy
  has_many :assignment_files,
           through: :criteria_assignment_files_joins
  accepts_nested_attributes_for :criteria_assignment_files_joins, allow_destroy: true

  self.abstract_class = true

  # Assigns a random TA from a list of TAs specified by +ta_ids+ to each
  # criterion in a list of criteria specified by +criterion_ids+. The criteria
  # must belong to the given assignment +assignment+.
  def self.randomly_assign_tas(criterion_ids_types, ta_ids, assignment)
    assign_tas(criterion_ids_types, ta_ids, assignment) do |criterion_ids, criterion_types, ta_ids|
      # Assign TAs in a round-robin fashion to a list of random criteria.
      crit_ids_and_types = criterion_ids.zip(criterion_types).shuffle
      crit_ids_and_types.zip(ta_ids.cycle).map &:flatten
    end
  end

  # Assigns all TAs in a list of TAs specified by +ta_ids+ to each criterion in
  # a list of criteria specified by +criterion_ids+. The criteria must belong
  # to the given assignment +assignment+.
  def self.assign_all_tas(criterion_ids_types, ta_ids, assignment)
    assign_tas(criterion_ids_types, ta_ids, assignment) do |criterion_ids, criterion_types, ta_ids|
      crit_ids_and_types = criterion_ids.zip(criterion_types)
      # Need to call Array#flatten because after the second product each element has
      # the form [[id, type], ta_id].
      crit_ids_and_types.product(ta_ids).map &:flatten
    end
  end

  # Assigns TAs to criteria using a caller-specified block. The block is given
  # a list of criterion IDs and a list of TA IDs and must return a list of
  # criterion-ID-TA-ID pair that represents the TA assignment.
  #
  #   # Assign the TA with ID 3 to the criterion with ID 1 and the TA
  #   # with ID 4 to the criterion with ID 2.
  #   assign_tas([1, 2], [3, 4], a) do |criterion_ids, ta_ids|
  #     criterion_ids.zip(ta_ids)  # => [[1, 3], [2, 4]]
  #   end
  #
  # The criteria must belong to the given assignment +assignment+.
  def self.assign_tas(criterion_ids_types, ta_ids, assignment)
    criterion_ids_types   = Hash(criterion_ids_types)
    criterion_ids_in      = criterion_ids_types.values.map{ |id_type| id_type[0].to_i}
    criterion_types       = criterion_ids_types.values.map{ |id_type| id_type[1]}
    ta_ids                = Array(ta_ids)

    # Only use IDs that identify existing model instances.
    ta_ids = Ta.where(id: ta_ids).pluck(:id)
    criteria = assignment.get_criteria(:ta)
                         .select { |crit| criterion_ids_types.values.include? ["#{crit.id}", "#{crit.class}"] }
    columns = [:criterion_id, :criterion_type, :ta_id]
    # Get all existing criterion-TA associations to avoid violating the unique
    # constraint.
    existing_values = CriterionTaAssociation
                      .where(criterion_id: criteria.map(&:id),
                             ta_id: ta_ids)
                      .pluck(:criterion_id, :criterion_type, :ta_id)

    # Delegate the assign function to the caller-specified block and remove
    # values that already exist in the database.
    new_values = yield(criteria.map(&:id), criteria.map { |c| "#{c.class}" }, ta_ids)
    values = new_values - existing_values

    # Add assignment_id column common to all rows. It is not included above so
    # that the set operation is faster.
    columns << :assignment_id
    values.map { |value| value << assignment.id }
    # TODO replace CriterionTaAssociation.import with
    # CriterionTaAssociation.create when the PG driver supports bulk create,
    # then remove the activerecord-import gem.
    CriterionTaAssociation.import(columns, values, validate: false)

    Grouping.update_criteria_coverage_counts(assignment)
    criterion_ids_by_type = {}
    %w(RubricCriterion FlexibleCriterion CheckboxCriterion).each do |type|
      criterion_ids_by_type[type] =
        criterion_ids_in.zip(criterion_types)
                        .select { |_, crit_type| crit_type == type}
                        .map { |crit_id, _| crit_id }
    end
    update_assigned_groups_counts(assignment, criterion_ids_by_type)
  end

  # Unassigns TAs from groupings. +criterion_ta_ids+ is a list of TA
  # membership IDs that specifies the unassignment to be done. +criterion_ids+
  # is a list of grouping IDs involved in the unassignment. The memberships
  # and groupings must belong to the given assignment +assignment+.
  def self.unassign_tas(criterion_ta_ids, criterion_ids_by_type, assignment)
    CriterionTaAssociation.where(id: criterion_ta_ids).delete_all

    Grouping.update_criteria_coverage_counts(assignment)
    update_assigned_groups_counts(assignment, criterion_ids_by_type)
  end

  # Updates the +assigned_groups_count+ field of all criteria that belong to
  # an assignment with ID +assignment_id+.
  def self.update_assigned_groups_counts(assignment, criterion_ids_by_type = nil)
    # Sanitize the IDs in the input.
    rubric_criterion_ids_str = generate_criterion_ids_str(criterion_ids_by_type, 'RubricCriterion')
    flexible_criterion_ids_str = generate_criterion_ids_str(criterion_ids_by_type, 'FlexibleCriterion')
    checkbox_criterion_ids_str = generate_criterion_ids_str(criterion_ids_by_type, 'CheckboxCriterion')

    # TODO replace these raw SQL with dynamic SET clause with Active Record
    # language when the latter supports subquery in the SET clause.
    criteria_str = Hash.new
    criteria_str[RubricCriterion] = rubric_criterion_ids_str
    criteria_str[FlexibleCriterion] = flexible_criterion_ids_str
    criteria_str[CheckboxCriterion] = checkbox_criterion_ids_str

    criteria_str.each do |criterion, str|
      criterion.connection.execute(<<-UPDATE_SQL)
      UPDATE #{criterion.table_name} AS c SET assigned_groups_count =
        (SELECT count(DISTINCT g.id) FROM memberships AS m
          INNER JOIN groupings AS g ON m.grouping_id = g.id
          INNER JOIN criterion_ta_associations AS ct ON m.user_id = ct.ta_id
          WHERE g.assignment_id = #{assignment.id}
            AND ct.criterion_id = c.id AND ct.assignment_id = c.assignment_id
            AND m.type = 'TaMembership')
        WHERE assignment_id = #{assignment.id}
      #{"AND id IN (#{str})" unless str.empty?}
      UPDATE_SQL
    end
  end

  def self.generate_criterion_ids_str(criterion_ids_by_type, type)
    if criterion_ids_by_type.nil? or criterion_ids_by_type[type].nil?
      ''
    else
      Array(criterion_ids_by_type[type])
                                   .map { |criterion_id| connection.quote(criterion_id) }
                                   .join(',')
    end
  end

  # When max_mark of criterion is changed, all associated marks should have their mark value scaled to the change.
  def scale_marks
    if max_mark_changed? && !max_mark_was.nil?  # if max_mark is updated
      # results with specific assignment
      results = Result.includes(submission: :grouping)
                      .where(groupings: {assignment_id: assignment_id})
      all_marks = marks.where.not(mark: nil).where(result_id: results.ids)
      # all associated marks should have their mark value scaled to the change.
      Upsert.batch(Mark.connection, Mark.table_name) do |upsert|
        all_marks.each do |m|
          upsert.row({ id: m.id }, mark: m.scale_mark(max_mark, max_mark_was, update: false) )
        end
      end
      a = Assignment.find(assignment_id)
      Upsert.batch(Result.connection, Result.table_name) do |upsert|
        results.each do |r|
          upsert.row({ id: r.id }, total_mark: r.get_total_mark(assignment: a))
        end
      end
      a.assignment_stat.refresh_grade_distribution
    end
  end

  private

  # Checks if the criterion is visible to either the ta or the peer reviewer.
  def visible?
    if ta_visible || peer_visible
      true
    else
      errors.add(:base, I18n.t('activerecord.errors.models.criterion.visibility_error'))
      false
    end
  end
end
