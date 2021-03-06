require "test_helper"

class PostsControllerTest < ActionDispatch::IntegrationTest
  context "The posts controller" do
    setup do
      PopularSearchService.stubs(:enabled?).returns(false)

      @user = travel_to(1.month.ago) {create(:user)}
      as_user do
        @post = create(:post, :tag_string => "aaaa")
      end
    end

    context "index action" do
      should "render" do
        get posts_path
        assert_response :success
      end

      context "with a single tag search" do
        should "render for an empty tag" do
          get posts_path, params: { tags: "does_not_exist" }
          assert_response :success
        end

        should "render for an artist tag" do
          create(:post, tag_string: "artist:bkub")
          get posts_path, params: { tags: "bkub" }
          assert_response :success

          artist = create(:artist, name: "bkub")
          get posts_path, params: { tags: "bkub" }
          assert_response :success

          artist.update(is_banned: true)
          get posts_path, params: { tags: "bkub" }
          assert_response :success

          artist.update(is_banned: false, is_deleted: true)
          get posts_path, params: { tags: "bkub" }
          assert_response :success

          as_user { create(:wiki_page, title: "bkub") }
          get posts_path, params: { tags: "bkub" }
          assert_response :success
        end

        should "render for a tag with a wiki page" do
          create(:post, tag_string: "char:fumimi")
          get posts_path, params: { tags: "fumimi" }
          assert_response :success

          as_user { @wiki = create(:wiki_page, title: "fumimi") }
          get posts_path, params: { tags: "fumimi" }
          assert_response :success

          as_user { @wiki.update(is_deleted: true) }
          get posts_path, params: { tags: "bkub" }
          assert_response :success
        end

        should "render for a wildcard tag search" do
          create(:post, tag_string: "1girl solo")
          get posts_path(tags: "*girl*")
          assert_response :success
        end

        should "render for a search:all search" do
          create(:saved_search, user: @user)
          get posts_path(tags: "search:all")
          assert_response :success
        end
      end

      context "with a multi-tag search" do
        should "render" do
          create(:post, tag_string: "1girl solo")
          get posts_path, params: {:tags => "1girl solo"}
          assert_response :success
        end

        should "render an error when searching for too many tags" do
          get posts_path, params: { tags: "1 2 3" }

          assert_response 422
          assert_select "h1", "Search Error"
        end

        should "render an error when exceeding the page limit" do
          get posts_path, params: { page: 1001 }

          assert_response 410
          assert_select "h1", "Search Error"
        end
      end

      context "with an md5 param" do
        should "render" do
          get posts_path, params: { md5: @post.md5 }
          assert_redirected_to(@post)
        end

        should "return error on nonexistent md5" do
          get posts_path(md5: "foo")
          assert_response 404
        end
      end

      context "with a random search" do
        should "render" do
          get posts_path, params: { tags: "order:random" }
          assert_response :success

          get posts_path, params: { random: "1" }
          assert_response :success

          get posts_path(format: :json), params: { random: "1" }
          assert_response :success
        end

        should "render with multiple posts" do
          @posts = create_list(:post, 2)

          get posts_path, params: { random: "1" }
          assert_response :success
        end
      end

      context "with the .atom format" do
        should "render without tags" do
          get posts_path(format: :atom)

          assert_response :success
          assert_select "entry", 1
        end

        should "render with tags" do
          get posts_path(format: :atom), params: { tags: "aaaa" }

          assert_response :success
          assert_select "entry", 1
        end

        should "hide restricted posts" do
          @post.update(is_banned: true)
          get posts_path(format: :atom)

          assert_response :success
          assert_select "entry", 0
        end
      end

      context "with deleted posts" do
        setup do
          @post.update!(is_deleted: true)
        end

        should "not show deleted posts normally" do
          get posts_path
          assert_response :success
          assert_select "#post_#{@post.id}", 0
        end

        should "show deleted posts when searching for status:deleted" do
          get posts_path(tags: "status:deleted")
          assert_response :success
          assert_select "#post_#{@post.id}", 1
        end
      end

      context "with restricted posts" do
        setup do
          Danbooru.config.stubs(:restricted_tags).returns(["tagme"])
          as(@user) { @post.update!(tag_string: "tagme") }
        end

        should "not show restricted posts if user doesn't have permission" do
          get posts_path
          assert_response :success
          assert_select "#post_#{@post.id}", 0
        end

        should "show restricted posts if user has permission" do
          get_auth posts_path, create(:gold_user)
          assert_response :success
          assert_select "#post_#{@post.id}", 1
        end
      end
    end

    context "show_seq action" do
      should "render" do
        posts = FactoryBot.create_list(:post, 3)

        get show_seq_post_path(posts[1].id), params: { seq: "prev" }
        assert_redirected_to(posts[2])

        get show_seq_post_path(posts[1].id), params: { seq: "next" }
        assert_redirected_to(posts[0])
      end
    end

    context "random action" do
      should "render" do
        get random_posts_path, params: { tags: "aaaa" }
        assert_redirected_to(post_path(@post, tags: "aaaa"))
      end

      should "return a 404 when no random posts can be found" do
        get random_posts_path, params: { tags: "qoigjegoi" }
        assert_response 404
      end
    end

    context "show action" do
      should "render" do
        get post_path(@post), params: {:id => @post.id}
        assert_response :success
      end

      context "with everything" do
        setup do
          @admin = create(:admin_user, can_approve_posts: true)
          @builder = create(:builder_user, can_approve_posts: true)

          as(@user) do
            @post.update!(tag_string: "1girl solo highres blah 2001")
            Tag.find_by_name("1girl").update(post_count: 20_000)
            Tag.find_by_name("solo").update(post_count: 2_000)
            Tag.find_by_name("blah").update(post_count: 1)

            @pool = create(:pool)
            @pool.add!(@post)

            @favgroup = create(:favorite_group)
            @favgroup.add!(@post)

            @comment = create(:comment, post: @post, creator: @admin)
            create(:comment_vote, comment: @comment, user: @user)

            create(:note, post: @post)
            create(:artist_commentary, post: @post)
            create(:post_flag, post: @post, creator: @user)
            create(:post_appeal, post: @post, creator: @user)
            create(:post_vote, post: @post, user: @user)
            create(:favorite, post: @post, user: @user)
            create(:moderation_report, model: @comment, creator: @builder)
          end
        end

        should "render for an anonymous user" do
          get post_path(@post)
          assert_response :success
        end

        should "render for a member" do
          get_auth post_path(@post), @user
          assert_response :success
        end

        should "render for a builder" do
          get_auth post_path(@post), @builder
          assert_response :success
        end

        should "render for an admin" do
          get_auth post_path(@post), @admin
          assert_response :success
        end

        should "render for a builder with a search query" do
          get_auth post_path(@post, q: "tagme"), @builder
          assert_response :success
        end
      end

      context "with pools" do
        should "render the pool list" do
          as(@user) { @post.update(tag_string: "newpool:comic") }
          get post_path(@post)

          assert_response :success
          assert_select "#pool-nav .pool-name", /Pool: comic/
        end
      end

      context "with only deleted comments" do
        setup do
          as(@user) { create(:comment, creator: @user, post: @post, is_deleted: true) }
        end

        should "not show deleted comments to regular members" do
          get_auth post_path(@post), @user, params: { id: @post.id }

          assert_response :success
          assert_select "article.comment", 0
          assert_select "a#show-all-comments-link", 0
          assert_select "div.list-of-comments p", /There are no comments/
        end

        should "not show deleted comments to moderators by default, but allow them to be unhidden" do
          mod = create(:mod_user)
          get_auth post_path(@post), mod, params: { id: @post.id }

          assert_response :success
          assert_select "article.comment", 0
          assert_select "a#show-all-comments-link", 1
          assert_select "div.list-of-comments p", /There are no comments/
        end
      end

      context "with only downvoted comments" do
        should "not show thresholded comments" do
          comment = as(@user) { create(:comment, creator: @user, post: @post, score: -10) }
          get_auth post_path(@post), @user, params: { id: @post.id }

          assert_response :success
          assert_select "article.comment", 0
          assert_select "a#show-all-comments-link", 1
          assert_select "div.list-of-comments p", /There are no visible comments/
        end
      end

      context "with a mix of comments" do
        should "not show deleted or thresholded comments " do
          as(@user) { create(:comment, creator: @user, post: @post, do_not_bump_post: true, body: "good") }
          as(@user) { create(:comment, creator: @user, post: @post, do_not_bump_post: true, body: "bad", score: -10) }
          as(@user) { create(:comment, creator: @user, post: @post, do_not_bump_post: true, body: "ugly", is_deleted: true) }

          get_auth post_path(@post), @user, params: { id: @post.id }

          assert_response :success
          assert_select "article.comment", 1
          assert_select "article.comment", /good/
          assert_select "a#show-all-comments-link", 1
        end
      end

      context "when the recommend service is enabled" do
        setup do
          @post2 = create(:post)
          RecommenderService.stubs(:enabled?).returns(true)
          RecommenderService.stubs(:available_for_post?).returns(true)
        end

        should "not error out" do
          get_auth post_path(@post), @user
          assert_response :success
        end
      end

      context "in api responses" do
        should "not include restricted attributes" do
          Post.any_instance.stubs(:visible?).returns(false)
          get_auth post_path(@post), @user, as: :json

          assert_response :success
          assert_nil(response.parsed_body["md5"])
          assert_nil(response.parsed_body["file_url"])
          assert_nil(response.parsed_body["fav_string"])
        end
      end
    end

    context "update action" do
      should "work" do
        put_auth post_path(@post), @user, params: {:post => {:tag_string => "bbb"}}
        assert_redirected_to post_path(@post)

        @post.reload
        assert_equal("bbb", @post.tag_string)
      end

      should "ignore restricted params" do
        put_auth post_path(@post), @user, params: {:post => {:last_noted_at => 1.minute.ago}}
        assert_nil(@post.reload.last_noted_at)
      end

      should "not allow unprivileged users to update restricted posts" do
        as(@user) { @post.update!(is_banned: true) }
        put_auth post_path(@post), @user, params: { post: { tag_string: "blah" }}
        assert_response 403
        assert_not_equal("blah", @post.reload.tag_string)
      end

      should "not allow unverified users to update posts" do
        @user.update!(requires_verification: true, is_verified: false)
        put_auth post_path(@post), @user, params: { post: { tag_string: "blah" }}
        assert_response 403
        assert_not_equal("blah", @post.reload.tag_string)
      end
    end

    context "revert action" do
      setup do
        PostVersion.sqs_service.stubs(:merge?).returns(false)
        as_user do
          @post.update(tag_string: "zzz")
        end
      end

      should "work" do
        @version = @post.versions.first
        assert_equal("aaaa", @version.tags)
        put_auth revert_post_path(@post), @user, params: {:version_id => @version.id}
        assert_redirected_to post_path(@post)
        @post.reload
        assert_equal("aaaa", @post.tag_string)
      end

      should "not allow reverting to a previous version of another post" do
        as_user do
          @post2 = create(:post, :uploader_id => @user.id, :tag_string => "herp")
        end

        put_auth revert_post_path(@post), @user, params: { :version_id => @post2.versions.first.id }
        @post.reload
        assert_not_equal(@post.tag_string, @post2.tag_string)
        assert_response :missing
      end
    end

    context "copy_notes action" do
      setup do
        as(@user) do
          @src = create(:post, image_width: 100, image_height: 100, tag_string: "translated partially_translated", has_embedded_notes: true)
          @dst = create(:post, image_width: 200, image_height: 200, tag_string: "translation_request")
          create(:note, post: @src, x: 10, y: 10, width: 10, height: 10, body: "test")
          create(:note, post: @src, x: 10, y: 10, width: 10, height: 10, body: "deleted", is_active: false)
        end
      end

      should "copy notes and tags" do
        put_auth copy_notes_post_path(@src), @user, params: { other_post_id: @dst.id }
        assert_response :success

        assert_equal(1, @dst.reload.notes.active.length)
        assert_equal(true, @dst.has_embedded_notes)
        assert_equal("lowres partially_translated translated", @dst.tag_string)
      end

      should "rescale notes" do
        put_auth copy_notes_post_path(@src), @user, params: { other_post_id: @dst.id }
        assert_response :success

        note = @dst.notes.active.first
        assert_equal([20, 20, 20, 20], [note.x, note.y, note.width, note.height])
      end
    end

    context "mark_as_translated action" do
      should "mark the post as translated" do
        put_auth mark_as_translated_post_path(@post), @user, params: { post: { check_translation: false, partially_translated: false }}
        assert_redirected_to @post
        assert(@post.reload.has_tag?("translated"))
      end
    end
  end
end
