# frozen_string_literal: true

require 'rails_helper'

# A resident's own profile (ADR 0014): GET and PATCH /api/v1/profile, the
# email change link (POST /api/v1/profile/email-link), and opening it
# (POST /api/v1/profile/email-confirm).
RSpec.describe 'A resident profile' do
  let!(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) do
    create(:resident, community: community, unit: unit, name: 'Ann Lee', email: 'ann@example.com', vegetarian: false)
  end
  let(:headers) { { 'Authorization' => "Bearer #{JwtAuth.encode(resident)}" } }
  let(:child) { create(:resident, community: community, unit: unit, name: 'Kid Lee', email: nil, multiplier: 1) }

  def save(fields, as: headers)
    patch '/api/v1/profile', params: fields, headers: as, as: :json
  end

  def fields(**changes)
    { name: resident.name, vegetarian: resident.vegetarian, email: resident.email }.merge(changes)
  end

  def message
    response.parsed_body['message']
  end

  # The token in the newest link email, as the person's mail app sees it.
  def emailed_token
    mail = ActionMailer::Base.deliveries.rfind { |m| m.subject == 'Confirm your new email' }
    mail.text_part.body.to_s[/confirm-email#token=(\S+)/, 1]
  end

  def confirm(token)
    post '/api/v1/profile/email-confirm', params: { email_token: token }, as: :json
  end

  def fail_the(mailer_method)
    allow(ResidentMailer).to receive(mailer_method).and_wrap_original do |original, *args|
      original.call(*args).tap { |mail| allow(mail).to receive(:deliver_now).and_raise(Net::ReadTimeout) }
    end
  end

  before { ActionMailer::Base.deliveries.clear }

  describe 'GET /api/v1/profile' do
    it 'shows the signed-in resident, and the children in their unit who have no email' do
      child
      get '/api/v1/profile', headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(
        'id' => resident.id, 'name' => 'Ann Lee', 'username' => 'Ann', 'email' => 'ann@example.com',
        'pending_email' => nil, 'vegetarian' => false,
        'children' => [{ 'id' => child.id, 'name' => 'Kid Lee', 'vegetarian' => false }]
      )
    end

    it 'leaves out a child with an email, an adult with none, a retired child, and other units' do
      create(:resident, community: community, unit: unit, multiplier: 1, email: 'teen@example.com')
      create(:resident, community: community, unit: unit, email: nil, can_cook: false)
      create(:resident, community: community, unit: unit, multiplier: 1, email: nil, active: false)
      create(:resident, community: community, multiplier: 1, email: nil)

      get '/api/v1/profile', headers: headers

      expect(response.parsed_body['children']).to eq([])
    end

    it 'lists the children by name' do
      create(:resident, community: community, unit: unit, name: 'Zed Lee', email: nil, multiplier: 1)
      create(:resident, community: community, unit: unit, name: 'Amy Lee', email: nil, multiplier: 1)

      get '/api/v1/profile', headers: headers

      expect(response.parsed_body['children'].pluck('name')).to eq(['Amy Lee', 'Zed Lee'])
    end

    it 'shows a child who signs in no one else to edit' do
      teen = create(:resident, community: community, unit: unit, multiplier: 1, email: 'teen@example.com')
      child

      get '/api/v1/profile', headers: { 'Authorization' => "Bearer #{JwtAuth.encode(teen)}" }

      expect(response.parsed_body['children']).to eq([])
    end

    it 'refuses a request that is not signed in' do
      get '/api/v1/profile'

      expect(response).to have_http_status(:unauthorized)
    end

    # The screen is signed in, so 403, not a 401 that would show it as
    # signed out.
    it 'refuses the Common House screen, which has no profile' do
      login = create(:common_house_login)
      get '/api/v1/profile', headers: { 'Authorization' => "Bearer #{JwtAuth.encode(login)}" }

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'PATCH /api/v1/profile' do
    it 'saves the name and the vegetarian setting, with the spaces around the name taken off' do
      save(fields(name: '  Ann Marie Lee ', vegetarian: true))

      expect(response).to have_http_status(:ok)
      expect(message).to eq('Your profile has been saved.')
      expect(resident.reload).to have_attributes(name: 'Ann Marie Lee', vegetarian: true)
      expect(response.parsed_body['profile']).to include('name' => 'Ann Marie Lee', 'username' => 'Ann',
                                                         'vegetarian' => true)
    end

    it "saves a child's name and vegetarian setting in the same save" do
      save(fields(children: [{ id: child.id, name: 'Kit Lee', vegetarian: true }]))

      expect(response).to have_http_status(:ok)
      expect(child.reload).to have_attributes(name: 'Kit Lee', vegetarian: true)
      expect(response.parsed_body.dig('profile', 'children')).to eq(
        [{ 'id' => child.id, 'name' => 'Kit Lee', 'vegetarian' => true }]
      )
    end

    it 'takes a child id sent as text' do
      save(fields(children: [{ id: child.id.to_s, name: 'Kit Lee', vegetarian: false }]))

      expect(response).to have_http_status(:ok)
      expect(child.reload.name).to eq('Kit Lee')
    end

    # Integer('012') would read it as a number in base 8.
    it 'reads a child id sent as text with a zero in front as a number in base 10' do
      save(fields(children: [{ id: "0#{child.id}", name: 'Kit Lee', vegetarian: false }]))

      expect(response).to have_http_status(:ok)
      expect(child.reload.name).to eq('Kit Lee')
    end

    it 'turns the vegetarian setting off, for the resident and for a child' do
      resident.update!(vegetarian: true)
      child.update!(vegetarian: true)

      save(fields(vegetarian: false, children: [{ id: child.id, name: 'Kid Lee', vegetarian: false }]))

      expect(response).to have_http_status(:ok)
      expect(resident.reload.vegetarian).to be(false)
      expect(child.reload.vegetarian).to be(false)
    end

    it "takes the spaces off both ends of a child's name" do
      save(fields(children: [{ id: child.id, name: '  Kit Lee  ', vegetarian: false }]))

      expect(child.reload.name).to eq('Kit Lee')
    end

    # Each child's save checks its own name against the other residents,
    # one query for each child. That is the same query again and again on
    # purpose, so the N+1 check is off here.
    it 'saves every child sent', prosopite: false do
      kim = create(:resident, community: community, unit: unit, name: 'Kim Lee', email: nil, multiplier: 1)

      save(fields(children: [{ id: child.id, name: 'Kit Lee', vegetarian: false },
                             { id: kim.id, name: 'Kimberly Lee', vegetarian: true }]))

      expect(response).to have_http_status(:ok)
      expect(child.reload.name).to eq('Kit Lee')
      expect(kim.reload).to have_attributes(name: 'Kimberly Lee', vegetarian: true)
    end

    it 'names every refused change, one to a line' do
      kim = create(:resident, community: community, unit: unit, name: 'Kim Lee', email: nil, multiplier: 1)

      save(fields(children: [{ id: child.id, name: ' ', vegetarian: false },
                             { id: kim.id, name: ' ', vegetarian: false }]))

      expect(response).to have_http_status(:bad_request)
      expect(message).to eq("Kid Lee: Name can't be blank\nKim Lee: Name can't be blank")
    end

    it 'refuses a name another resident has, in the words the admin form uses, and saves nothing' do
      create(:resident, community: community, name: 'Bo Diaz')
      save(fields(name: 'bo diaz', vegetarian: true))

      expect(response).to have_http_status(:bad_request)
      expect(message).to start_with('Name is already used by the resident in unit')
      expect(resident.reload).to have_attributes(name: 'Ann Lee', vegetarian: false)
    end

    it "names the child whose change was refused, and saves nothing, the parent's part included" do
      save(fields(name: 'Ann Marie Lee', children: [{ id: child.id, name: ' ', vegetarian: true }]))

      expect(response).to have_http_status(:bad_request)
      expect(message).to eq("Kid Lee: Name can't be blank")
      expect(resident.reload.name).to eq('Ann Lee')
      expect(child.reload.vegetarian).to be(false)
    end

    {
      'a child in another unit' => -> { create(:resident, community: community, multiplier: 1, email: nil) },
      'a child with an email' => lambda {
        create(:resident, community: community, unit: unit, multiplier: 1, email: 'teen@example.com')
      },
      'an adult in the unit' => -> { create(:resident, community: community, unit: unit) },
      'the resident themselves' => -> { resident }
    }.each do |who, make|
      it "refuses #{who}, and saves nothing" do
        other = instance_exec(&make)
        save(fields(vegetarian: true, children: [{ id: other.id, name: 'Someone Else', vegetarian: true }]))

        expect(response).to have_http_status(:bad_request)
        expect(message).to eq(ProfileUpdate::ONLY_YOUR_CHILDREN)
        expect(resident.reload.vegetarian).to be(false)
        expect(other.reload.name).not_to eq('Someone Else')
      end
    end

    it 'refuses a child who signs in editing a brother or sister' do
      teen = create(:resident, community: community, unit: unit, multiplier: 1, email: 'teen@example.com')
      teen_headers = { 'Authorization' => "Bearer #{JwtAuth.encode(teen)}" }
      save({ name: teen.name, vegetarian: false, email: teen.email,
             children: [{ id: child.id, name: 'Kit Lee', vegetarian: false }] }, as: teen_headers)

      expect(response).to have_http_status(:bad_request)
      expect(child.reload.name).to eq('Kid Lee')
    end

    {
      { name: 5 } => 'Name must be text.',
      { email: nil } => 'Email must be text.',
      { vegetarian: 'maybe' } => 'Vegetarian must be true or false.',
      { children: 'Kid' } => 'Children must be a list.',
      { children: ['Kid'] } => 'Each child must have an id, a name and a vegetarian setting.',
      { children: [{ id: 'one', name: 'Kid', vegetarian: true }] } =>
        'Each child must have an id, a name and a vegetarian setting.',
      { children: [{ id: 1, name: 'Kid', vegetarian: 'yes' }] } =>
        'Each child must have an id, a name and a vegetarian setting.',
      { children: [{ id: 1, name: nil, vegetarian: true }] } =>
        'Each child must have an id, a name and a vegetarian setting.',
      { children: [{ id: 1, name: 5, vegetarian: true }] } =>
        'Each child must have an id, a name and a vegetarian setting.',
      { children: [{ id: 2.5, name: 'Kid', vegetarian: true }] } =>
        'Each child must have an id, a name and a vegetarian setting.',
      { children: [{ name: 'Kid', vegetarian: true }] } =>
        'Each child must have an id, a name and a vegetarian setting.',
      { children: [{ id: 1, vegetarian: true }] } =>
        'Each child must have an id, a name and a vegetarian setting.',
      { children: [{ id: 1, name: 'Kid' }] } =>
        'Each child must have an id, a name and a vegetarian setting.'
    }.each do |change, words|
      it "refuses #{change.inspect} with: #{words}" do
        save(fields(**change))

        expect(response).to have_http_status(:bad_request)
        expect(message).to eq(words)
      end
    end

    it 'names every problem with the request, one to a line' do
      save({ name: nil, vegetarian: nil, email: 3 })

      expect(message).to eq("Name must be text.\nEmail must be text.\nVegetarian must be true or false.")
    end

    it 'gives the same answer for a request with no fields at all' do
      save({})

      expect(response).to have_http_status(:bad_request)
      expect(message).to eq("Name must be text.\nEmail must be text.\nVegetarian must be true or false.")
    end

    it 'refuses the same child twice' do
      row = { id: child.id, name: 'Kit Lee', vegetarian: true }
      save(fields(children: [row, row]))

      expect(response).to have_http_status(:bad_request)
      expect(message).to eq('Each child can be sent only once.')
    end

    it 'refuses the Common House screen' do
      login = create(:common_house_login)
      save(fields(vegetarian: true), as: { 'Authorization' => "Bearer #{JwtAuth.encode(login)}" })

      expect(response).to have_http_status(:forbidden)
      expect(resident.reload.vegetarian).to be(false)
    end

    it 'refuses a request that is not signed in' do
      save(fields(vegetarian: true), as: {})

      expect(response).to have_http_status(:unauthorized)
    end

    describe 'the email' do
      it 'sends no email when the address does not change, whatever its case and spaces' do
        save(fields(email: ' ANN@example.com '))

        expect(response).to have_http_status(:ok)
        expect(ActionMailer::Base.deliveries).to be_empty
        expect(resident.reload.pending_email).to be_nil
      end

      it 'keeps the old address until the link is opened, and mails the link and a notice' do
        save(fields(email: 'Ann.New@Example.com'))

        expect(response).to have_http_status(:ok)
        expect(message).to eq('Your profile has been saved. To change your email, open the link we sent to ' \
                              'ann.new@example.com. Until then, sign in with ann@example.com.')
        expect(resident.reload).to have_attributes(email: 'ann@example.com', pending_email: 'ann.new@example.com')
        expect(response.parsed_body.dig('profile', 'pending_email')).to eq('ann.new@example.com')
        expect(ActionMailer::Base.deliveries.map { |m| [m.to, m.subject] }).to eq(
          [[['ann.new@example.com'], 'Confirm your new email'],
           [['ann@example.com'], 'Your Comeals email is being changed']]
        )
      end

      it 'stores only the digest of the token' do
        save(fields(email: 'ann.new@example.com'))

        expect(resident.reload.email_change_token_digest).to eq(EmailChange.digest(emailed_token))
      end

      it 'leaves a waiting change waiting, and sends nothing, when the same new address is saved again' do
        save(fields(email: 'ann.new@example.com'))
        token = emailed_token
        ActionMailer::Base.deliveries.clear

        save(fields(email: 'ann.new@example.com', vegetarian: true))

        expect(ActionMailer::Base.deliveries).to be_empty
        confirm(token)
        expect(resident.reload.email).to eq('ann.new@example.com')
      end

      it 'takes a waiting change off when the old address is saved again, so its link stops working' do
        save(fields(email: 'ann.new@example.com'))
        token = emailed_token

        save(fields(email: 'ann@example.com'))

        expect(resident.reload.pending_email).to be_nil
        confirm(token)
        expect(response).to have_http_status(:bad_request)
        expect(message).to eq(EmailChange::UNKNOWN)
      end

      it 'makes only the newest link work' do
        save(fields(email: 'first@example.com'))
        first = emailed_token
        save(fields(email: 'second@example.com'))

        confirm(first)
        expect(response).to have_http_status(:bad_request)

        confirm(emailed_token)
        expect(resident.reload.email).to eq('second@example.com')
      end

      {
        '' => ['  ', 'Email cannot be blank.'],
        'not an address' => ['ann at example', 'Email is invalid'],
        'a .invalid address' => ['ann@comeals.invalid',
                                 'Email cannot end in .invalid. That address is for the Common House screen.'],
        "another resident's address" => ['bo@example.com', 'Email has already been taken']
      }.each do |what, (email, words)|
        it "refuses #{what}, and saves nothing" do
          create(:resident, community: community, email: 'bo@example.com')
          save(fields(email: email, vegetarian: true))

          expect(response).to have_http_status(:bad_request)
          expect(message).to eq(words)
          expect(resident.reload).to have_attributes(vegetarian: false, pending_email: nil)
          expect(ActionMailer::Base.deliveries).to be_empty
        end
      end

      # The model lets a resident who does not cook have no email. The
      # profile still refuses a blank one.
      it 'refuses a blank address from a resident who does not cook' do
        resident.update!(can_cook: false)
        save(fields(email: '  '))

        expect(response).to have_http_status(:bad_request)
        expect(message).to eq('Email cannot be blank.')
        expect(resident.reload.pending_email).to be_nil
      end

      it 'names every problem with the address, one to a line' do
        save(fields(email: "#{'a' * 256} at example"))

        expect(response).to have_http_status(:bad_request)
        expect(message).to eq("Email is too long (maximum is 255 characters)\nEmail is invalid")
      end

      # The token is 32 random bytes, written in 43 characters.
      it 'mails a token of 43 characters' do
        save(fields(email: 'ann.new@example.com'))

        expect(emailed_token).to match(/\A[A-Za-z0-9_-]{43}\z/)
      end

      it 'says the link did not go out, and keeps the change waiting, when its email fails' do
        fail_the(:email_change_link_email)
        save(fields(email: 'ann.new@example.com', vegetarian: true))

        expect(response).to have_http_status(:service_unavailable)
        expect(message).to eq('Your profile has been saved, but the email to ann.new@example.com could not be ' \
                              'sent. Use "Send the link again" on your profile, or ask an admin.')
        expect(response.parsed_body['profile']).to include('vegetarian' => true,
                                                           'pending_email' => 'ann.new@example.com')
        expect(resident.reload).to have_attributes(vegetarian: true, pending_email: 'ann.new@example.com')
      end

      it 'still answers that the link went out when only the notice fails' do
        fail_the(:email_change_notice_email)
        save(fields(email: 'ann.new@example.com'))

        expect(response).to have_http_status(:ok)
        expect(emailed_token).to be_present
      end

      # An admin can clear the email of a resident who is signed in.
      it 'sends no notice, and names no old address, when the resident has no email' do
        resident.update!(email: nil, can_cook: false)
        save(fields(email: 'ann.new@example.com'))

        expect(message).to eq('Your profile has been saved. To change your email, open the link we sent to ' \
                              'ann.new@example.com.')
        expect(ActionMailer::Base.deliveries.map(&:to)).to eq([['ann.new@example.com']])
      end
    end
  end

  describe 'POST /api/v1/profile/email-link' do
    def send_again(as: headers)
      post '/api/v1/profile/email-link', headers: as
    end

    it 'sends a new link to the waiting address, and the old link stops working' do
      save(fields(email: 'ann.new@example.com'))
      old_token = emailed_token
      ActionMailer::Base.deliveries.clear

      send_again

      expect(response).to have_http_status(:ok)
      expect(message).to eq('We sent a new link to ann.new@example.com.')
      expect(ActionMailer::Base.deliveries.map(&:to)).to eq([['ann.new@example.com']])
      new_token = emailed_token
      confirm(old_token)
      expect(response).to have_http_status(:bad_request)
      confirm(new_token)
      expect(resident.reload.email).to eq('ann.new@example.com')
    end

    # Another field on the row can be invalid (#105). It must not stop a
    # link that only changes the three email change columns.
    it 'sends the link even when another field on the row is invalid' do
      save(fields(email: 'ann.new@example.com'))
      resident.update_column(:name, '')

      send_again

      expect(response).to have_http_status(:ok)
    end

    it 'refuses when no change waits' do
      send_again

      expect(response).to have_http_status(:bad_request)
      expect(message).to eq(Api::V1::ProfilesController::NOTHING_WAITING)
    end

    it 'says when the link did not go out' do
      save(fields(email: 'ann.new@example.com'))
      fail_the(:email_change_link_email)

      send_again

      expect(response).to have_http_status(:service_unavailable)
      expect(message).to eq('The email to ann.new@example.com could not be sent. Try again later, or ask an admin.')
    end

    it 'refuses the Common House screen' do
      send_again(as: { 'Authorization' => "Bearer #{JwtAuth.encode(create(:common_house_login))}" })

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'POST /api/v1/profile/email-confirm' do
    before { save(fields(email: 'ann.new@example.com')) }

    it 'makes the waiting address the email, with no sign-in needed' do
      confirm(emailed_token)

      expect(response).to have_http_status(:ok)
      expect(message).to eq('Your email is now ann.new@example.com.')
      expect(resident.reload).to have_attributes(email: 'ann.new@example.com', pending_email: nil,
                                                 email_change_token_digest: nil, email_change_sent_at: nil)
    end

    it 'signs in with the new address after, and no longer with the old one' do
      resident.update!(password: 'a-password')
      confirm(emailed_token)

      post '/api/v1/residents/token', params: { email: 'ann@example.com', password: 'a-password' }
      expect(response).to have_http_status(:bad_request)
      post '/api/v1/residents/token', params: { email: 'ann.new@example.com', password: 'a-password' }
      expect(response).to have_http_status(:ok)
    end

    it 'works once' do
      token = emailed_token
      confirm(token)
      confirm(token)

      expect(response).to have_http_status(:bad_request)
      expect(message).to eq(EmailChange::UNKNOWN)
    end

    it 'refuses a link older than a day, and takes the change off' do
      resident.update_columns(email_change_sent_at: 25.hours.ago)
      confirm(emailed_token)

      expect(response).to have_http_status(:bad_request)
      expect(message).to eq(EmailChange::EXPIRED)
      expect(resident.reload).to have_attributes(email: 'ann@example.com', pending_email: nil)
    end

    it 'works until the day is over' do
      resident.update_columns(email_change_sent_at: 23.hours.ago)
      confirm(emailed_token)

      expect(response).to have_http_status(:ok)
    end

    it 'refuses an address someone else got in the meantime, and takes the change off' do
      create(:resident, community: community, email: 'ann.new@example.com')
      confirm(emailed_token)

      expect(response).to have_http_status(:bad_request)
      expect(message).to eq("Your email was not changed to ann.new@example.com:\nEmail has already been taken")
      expect(resident.reload).to have_attributes(email: 'ann@example.com', pending_email: nil)
    end

    # Two links to one address opened at the same moment: both pass the
    # model's check, and the unique index refuses the second.
    it 'gives the same answer when the unique index refuses the address' do
      allow_any_instance_of(Resident).to receive(:save).and_raise(ActiveRecord::RecordNotUnique) # rubocop:disable RSpec/AnyInstance
      confirm(emailed_token)

      expect(response).to have_http_status(:bad_request)
      expect(message).to eq("Your email was not changed to ann.new@example.com:\nEmail has already been taken")
      expect(resident.reload.pending_email).to be_nil
    end

    # Two links to one address, opened so close together that the model's
    # check passes for both. Here the check is turned off, so the database's
    # unique index is what refuses the address, with a real error. The
    # refusal must not stop the rest of the request's transaction.
    it 'gives the same answer when the database itself refuses the address' do
      create(:resident, community: community, email: 'ann.new@example.com')
      allow_any_instance_of(ActiveRecord::Validations::UniquenessValidator).to receive(:validate_each) # rubocop:disable RSpec/AnyInstance
      confirm(emailed_token)

      expect(response).to have_http_status(:bad_request)
      expect(message).to eq("Your email was not changed to ann.new@example.com:\nEmail has already been taken")
      expect(resident.reload).to have_attributes(email: 'ann@example.com', pending_email: nil)
    end

    it 'names the field that is wrong when another field on the row is invalid' do
      resident.update_column(:name, '')
      confirm(emailed_token)

      expect(response).to have_http_status(:bad_request)
      expect(message).to eq("Your email was not changed to ann.new@example.com:\nName can't be blank")
    end

    it 'names every other field that is wrong, one to a line' do
      resident.update_columns(name: '', phone: '+19999999999')
      confirm(emailed_token)

      expect(response).to have_http_status(:bad_request)
      expect(message.lines.map(&:chomp)).to eq(
        ['Your email was not changed to ann.new@example.com:',
         'Phone does not look like a real phone number. Enter it with the area code (510-555-2671). ' \
         'For a number outside the US, start with + and the country code (+44 20 7946 0958).',
         "Name can't be blank"]
      )
    end

    # When the address is the problem, the other fields are not named.
    it 'names only the address when the address is taken and another field is wrong too' do
      create(:resident, community: community, email: 'ann.new@example.com')
      resident.update_column(:name, '')
      confirm(emailed_token)

      expect(response).to have_http_status(:bad_request)
      expect(message).to eq("Your email was not changed to ann.new@example.com:\nEmail has already been taken")
    end

    it 'takes an expired change off even when another field on the row is invalid' do
      resident.update_columns(email_change_sent_at: 25.hours.ago, name: '')
      confirm(emailed_token)

      expect(response).to have_http_status(:bad_request)
      expect(message).to eq(EmailChange::EXPIRED)
      expect(resident.reload.pending_email).to be_nil
    end

    it 'refuses a request with no token in it' do
      post '/api/v1/profile/email-confirm', params: {}, as: :json

      expect(response).to have_http_status(:bad_request)
      expect(message).to eq(EmailChange::UNKNOWN)
    end

    [nil, 5, ['a'], 'not-a-token'].each do |token|
      it "refuses #{token.inspect} as no one's token" do
        confirm(token)

        expect(response).to have_http_status(:bad_request)
        expect(message).to eq(EmailChange::UNKNOWN)
      end
    end
  end
end
