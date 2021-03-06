require 'rails_helper'

describe Discussion do
  let(:discussion) { create :discussion }

  describe ".followers" do
    let(:follower) { FactoryGirl.create(:user) }
    let(:unfollower) { FactoryGirl.create(:user) }
    let(:group_follower) { FactoryGirl.create(:user) }
    let(:group_member) { FactoryGirl.create(:user) }
    let(:non_member) { FactoryGirl.create(:user) }
    let(:group) { discussion.group }

    before do
      [follower, unfollower, group_follower, group_member].each do |user|
        group.add_member!(user)
      end

      DiscussionReader.for(discussion: discussion, user: follower).follow!
      DiscussionReader.for(discussion: discussion, user: unfollower).unfollow!
      discussion.group.membership_for(group_follower).follow_by_default!
    end

    subject do
      discussion.followers
    end

    it {should include follower}
    it {should_not include unfollower}
    it {should include group_follower}
    it {should_not include group_member }
    it {should_not include non_member }
  end

  describe ".comment_deleted!" do
    after do
      discussion.comment_deleted!
    end

    it "resets last_comment_at" do
      discussion.should_receive(:refresh_last_comment_at!)
    end

    it "calls reset_counts on all discussion readers" do
      dr = DiscussionReader.for(discussion: discussion, user: discussion.author)
      dr.viewed!
      discussion.stub(:discussion_readers).and_return([dr])
      dr.should_receive(:reset_counts!)
    end
  end

  describe "archive!" do
    let(:discussion) { create :discussion }

    before do
      discussion.archive!
    end

    it "sets archived_at on the discussion" do
      discussion.archived_at.should be_present
    end
  end

  describe "#search(query)" do
    before { @user = create(:user) }
    it "returns user's discussions that match the query string" do
      discussion = create :discussion, title: "jam toast", author: @user
      @user.discussions.search("jam").should == [discussion]
    end
    it "does not return discussions that don't belong to the user" do
      discussion = create :discussion, title: "sandwich crumbs"
      @user.discussions.search("sandwich").should_not == [discussion]
    end
  end

  describe "#last_versioned_at" do
    it "returns the time the discussion was created at if no previous version exists" do
      Timecop.freeze do
        discussion = create :discussion
        discussion.last_versioned_at.iso8601.should == discussion.created_at.iso8601
      end
    end
    it "returns the time the previous version was created at" do
      discussion = create :discussion
      discussion.stub :has_previous_versions? => true
      discussion.stub_chain(:previous_version, :version, :created_at)
                .and_return 12345
      discussion.last_versioned_at.should == 12345
    end
  end

  context "versioning" do
    before do
      @discussion = create :discussion
      @version_count = @discussion.versions.count
      PaperTrail.enabled = true
    end

    it "doesn't create a new version when unrelevant attribute is edited" do
      @discussion.update_attribute :author, create(:user)
      @discussion.should have(@version_count).versions
    end

    it "creates a new version when discussion.description is edited" do
      @discussion.update_attribute :description, "new description"
      @discussion.should have(@version_count + 1).versions
    end
  end

  describe "#motions_count" do
    before do
      @user = create(:user)
      @group = create(:group)
      @discussion = create(:discussion, group: @group)
      @motion = create(:motion, discussion: @discussion)
    end

    it "returns a count of motions" do
      @discussion.reload.motions_count.should == 1
    end

    it "updates correctly after creating a motion" do
      expect {
        @discussion.motions.create(attributes_for(:motion).merge({ author: @user }))
      }.to change { @discussion.reload.motions_count }.by(1)
    end

    it "updates correctly after deleting a motion" do
      expect {
        @motion.destroy
      }.to change { @discussion.reload.motions_count }.by(-1)
    end

  end

  describe "#current_motion" do
    before do
      @discussion = create :discussion
      @motion = create :motion, discussion: @discussion
    end

    context "where motion is in open" do
      it "returns motion" do
        @discussion.current_motion.should eq(@motion)
      end
    end

    context "where motion close date has past" do
      before do
        @motion.closed_at = 3.days.ago
        @motion.save!
      end
      it "does not return motion" do
        @discussion.current_motion.should be_nil
      end
    end
  end

  describe "#participants" do
    before do
      @user1, @user2, @user3, @user4, @user_left_group =
        create(:user), create(:user), create(:user), create(:user), create(:user)
      @discussion = create :discussion, author: @user1
      @group = @discussion.group
      @group.add_member! @user2
      @group.add_member! @user3
      @group.add_member! @user4
      @group.add_member! @user_left_group
      DiscussionService.add_comment(build :comment, user: @user2, discussion: @discussion)
      DiscussionService.add_comment(build :comment, user: @user3, discussion: @discussion)
      DiscussionService.add_comment(build :comment, user: @user_left_group, discussion: @discussion)
      @group.membership_for(@user_left_group).destroy
    end

    it "should include users who have commented on discussion" do
      @discussion.participants.should include(@user2)
      @discussion.participants.should include(@user3)
    end

    it "should include the author of the discussion" do
      @discussion.participants.should include(@user1)
    end

    it "should include discussion motion authors (if any)" do
      previous_motion_author = create(:user)
      current_motion_author = create(:user)
      @group.add_member! previous_motion_author
      @group.add_member! current_motion_author
      previous_motion = create(:motion, discussion: @discussion, author: previous_motion_author)
      MotionService.close(previous_motion)
      current_motion = create(:motion, discussion: @discussion, author: current_motion_author)

      @discussion.participants.should include(previous_motion_author)
      @discussion.participants.should include(current_motion_author)
    end

    it "should not include users who have not commented on discussion" do
      @discussion.participants.should_not include(@user4)
    end

    it "should not include users who have since left the group" do
      @discussion.participants.should_not include(@user_left_group)
    end
  end

  describe "#viewed!" do
    before do
      @discussion = create :discussion
    end
    it "increases the total_views by 1" do
      @discussion.total_views.should == 0
      @discussion.viewed!
      @discussion.total_views.should == 1
    end
  end

  describe "#delayed_destroy" do
    it 'sets deleted_at before calling destroy and then destroys everything' do
      @motion = create(:motion, discussion: discussion)
      @vote = create(:vote, motion: @motion)
      discussion.should_receive(:is_deleted=).with(true)
      discussion.delayed_destroy
      Discussion.find_by_id(discussion.id).should be_nil
      Motion.find_by_id(@motion.id).should be_nil
      Vote.find_by_id(@vote.id).should be_nil
    end
  end

  describe '#inherit_group_privacy' do
    # provides a default when the discussion is new
    # when present passes the value on unmodified
    let(:discussion) { Discussion.new }
    let(:group) { Group.new }

    subject { discussion.private }

    context "new discussion" do
      context "with group associated" do
        before do
          discussion.group = group
        end

        context "group is private only" do
          before do
            group.discussion_privacy_options = 'private_only'
            discussion.inherit_group_privacy!
          end
          it { should be true }
        end

        context "group is public or private" do
          before do
            group.discussion_privacy_options = 'public_or_private'
            discussion.inherit_group_privacy!
          end
          it { should be_nil }
        end

        context "group is public only" do
          before do
            group.discussion_privacy_options = 'public_only'
            discussion.inherit_group_privacy!
          end
          it { should be false }
        end
      end

      context "without group associated" do
        it { should be_nil }
      end
    end
  end

  describe "validator: privacy_is_permitted_by_group" do
    let(:discussion) { Discussion.new }
    let(:group) { Group.new }
    subject { discussion }


    context "discussion is public when group is private only" do
      before do
        group.discussion_privacy_options = 'private_only'
        discussion.group = group
        discussion.private = false
        discussion.valid?
      end
      it {should have(1).errors_on(:private)}
    end
  end
end
