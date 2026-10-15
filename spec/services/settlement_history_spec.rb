# frozen_string_literal: true

require 'rails_helper'

# A settlement claims its meals with one UPDATE, which skips the model,
# so the audited gem wrote no history row for it, and a dinner's history
# never said it was settled. The settlement now writes the row a save of
# reconciliation_id would have written, one per meal it claims, in its
# own transaction, and the history says "Meal settled (settlement N)".
RSpec.describe Settlement do
  describe 'the history row of each meal it settles' do
    let(:community) { create(:community) }
    let(:unit) { create(:unit, community: community) }
    let(:latest) { Reconciliation.latest_cutoff(community.today) }
    let(:cook) { create(:resident, community: community, unit: unit) }
    let(:eater) { create(:resident, community: community, unit: unit) }
    let(:admin) { create(:admin_user, community: community, superuser: true) }

    def dinner(date)
      create(:meal, community: community, date: date).tap do |meal|
        create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('20'))
        create(:meal_resident, meal: meal, resident: eater, community: community)
      end
    end

    def settled_rows(meal)
      Audited::Audit.where(auditable_type: 'Meal', auditable_id: meal.id, action: 'update')
                    .where("audited_changes ? 'reconciliation_id'")
    end

    it 'writes one row per meal, the next version of each, and the history says it was settled' do
      first = dinner(latest - 1)
      second = dinner(latest)
      second.update!(description: 'Soup')
      before = Audited::Audit.where(auditable_type: 'Meal', auditable_id: [first.id, second.id])
                             .group(:auditable_id).maximum(:version)

      reconciliation = settle!

      rows = Audited::Audit.where(auditable_type: 'Meal', auditable_id: [first.id, second.id], action: 'update')
                           .where("audited_changes ? 'reconciliation_id'").order(:auditable_id).to_a
      expect(rows.map(&:auditable_id)).to eq([first.id, second.id])
      expect(rows.map(&:audited_changes)).to all(eq('reconciliation_id' => [nil, reconciliation.id]))
      expect(rows.map(&:version)).to eq([before.fetch(first.id) + 1, before.fetch(second.id) + 1])
      expect(AuditSerializer.new(second.reload.total_audits).to_h.first)
        .to include(description: "Meal settled (settlement #{reconciliation.id})")
    end

    it 'names the admin who settled, and nobody for the nightly task' do
      by_admin = dinner(latest - 1)
      Audited.audit_class.as_user(admin) { settle!(cutoff: latest - 1) }
      nightly = dinner(latest)
      settle!

      expect(settled_rows(by_admin).sole).to have_attributes(user: admin, request_uuid: be_present)
      expect(settled_rows(nightly).sole).to have_attributes(user_id: nil, user_type: nil, username: nil)
    end

    # Audited takes a name in place of a record, and keeps it as the name.
    it 'keeps a name given in place of a user' do
      meal = dinner(latest)
      Audited.audit_class.as_user('a script') { settle! }

      expect(settled_rows(meal).sole).to have_attributes(user_id: nil, user_type: nil, username: 'a script')
    end

    it 'writes no row when the settlement is refused' do
      meal = dinner(latest)

      expect { described_class.settle!(cutoff: latest, fingerprint: 'not what was shown') }
        .to raise_error(Settlement::Changed)
      expect(settled_rows(meal)).to be_empty
    end

    it 'writes no row for a settlement that only carries corrections' do
      meal = dinner(latest - 1)
      settle!(cutoff: latest - 1)
      MealCorrecting.save!(meal.reload, by: admin, reason: 'The receipt was $25') do |edits|
        edits.cost(cook, amount: BigDecimal('25'), no_cost: false)
      end

      settle!

      expect(settled_rows(meal).count).to eq(1)
    end
  end
end
