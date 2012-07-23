require 'uri'

require 'ghtorrent/api_client'
require 'ghtorrent/settings'
require 'ghtorrent/utils'
require 'ghtorrent/gh_torrent_exception'

module GHTorrent
  module Retriever

    include GHTorrent::Settings
    include GHTorrent::Utils
    include GHTorrent::APIClient

    def ext_uniq
      raise Exception("Unimplemented")
    end

    def persister
      raise Exception("Unimplemented")
    end

    def retrieve_user_byusername(user)
      stored_user = persister.find(:users, {'login' => user})
      if stored_user.empty?
        url = ghurl "users/#{user}"
        u = api_request(url)

        if u.empty?
          throw GHTorrentException.new("Cannot find user #{user}")
        end

        unq = persister.store(:users, u)
        u[ext_uniq] = unq
        what = user_type(u['type'])
        info "Retriever: New #{what} #{user}"
        u
      else
        what = user_type(stored_user.first['type'])
        debug "Retriever: Already got #{what} #{user}"
        stored_user.first
      end
    end

    # Try Github user search by email. This is optional info, so
    # it may not return any data.
    # http://developer.github.com/v3/search/#email-search
    def retrieve_user_byemail(email, name)
      url = ghurl("legacy/user/email/#{URI.escape(email)}")
      r = api_request(url)

      return nil if r.empty?
      r
    end

    def retrieve_user_followers(user)
      stored_followers = persister.find(:followers, {'follows' => user})

      followers = paged_api_request(ghurl "users/#{user}/followers")
      followers.each do |x|
        x['follows'] = user

        exists = !stored_followers.find { |f|
          f['follows'] == user && f['login'] == x['login']
        }.nil?

        if not exists
          persister.store(:followers, x)
          info "Retriever: Added follower #{user} -> #{x['login']}"
        else
          debug "Retriever: Follower #{user} -> #{x['login']} exists"
        end
      end

      persister.find(:followers, {'follows' => user})
    end

    # Retrieve a single commit from a repo
    def retrieve_commit(repo, sha, user)
      commit = persister.find(:commits, {'sha' => "#{sha}"})

      if commit.empty?
        url = ghurl "repos/#{user}/#{repo}/commits/#{sha}"
        c = api_request(url)

        if c.empty?
          throw GHTorrentException.new("Cannot find commit #{user}/#{repo}/#{sha}")
        end

        unq = persister.store(:commits, c)
        info "Retriever: New commit #{repo} -> #{sha}"
        c[ext_uniq] = unq
        c
      else
        debug "Retriever: Already got commit #{repo} -> #{sha}"
        commit.first
      end
    end

    # Retrieve all project commits or 500 (whatever comes first),
    # starting from the provided +sha+
    def retrieve_commits(repo, sha, user)
      last_sha = if sha.nil?
                  "master"
                 else
                  sha
                 end

      url = ghurl "repos/#{user}/#{repo}/commits?last_sha=#{last_sha}"
      commits = paged_api_request(url, config(:mirror_commit_pages_new_repo))

      commits.map do |c|
        retrieve_commit(repo, c['sha'], user)
      end
    end


    def retrieve_repo(user, repo)
      stored_repo = persister.find(:repos, {'owner.login' => user,
                                             'name' => repo })
      if stored_repo.empty?
        url = ghurl "repos/#{user}/#{repo}"
        r = api_request(url)

        if r.empty?
          throw GHTorrentException.new("Cannot find repo #{user}/#{repo}")
        end

        unq = persister.store(:repos, r)
        info "Retriever: New repo #{user} -> #{repo}"
        r[ext_uniq] = unq
        r
      else
        debug "Retriever: Already got repo #{user} -> #{repo}"
        stored_repo.first
      end
    end

    # Retrieve organizations the provided user participates into
    def retrieve_orgs(user)
      url = ghurl "users/#{user}/orgs"
      orgs = paged_api_request(url)
      orgs.map{|o| retrieve_org(o['login'])}
    end

    # Retrieve a single organization
    def retrieve_org(org)
      retrieve_user_byusername(org)
    end

    # Retrieve organization members
    def retrieve_org_members(org)
      stored_org_members = persister.find(:org_members, {'org' => org})

      org_members = paged_api_request(ghurl "orgs/#{org}/members")
      org_members.each do |x|
        x['org'] = org

        exists = !stored_org_members.find { |f|
          f['org'] == user && f['login'] == x['login']
        }.nil?

        if not exists
          persister.store(:org_members, x)
          info "Retriever: Added member #{org} -> #{x['login']}"
        else
          debug "Retriever: Member #{org} -> #{x['login']} exists"
        end
      end

      persister.find(:org_members, {'org' => org}).map{|o| retrieve_org(o['login'])}
    end

    # Retrieve all comments for a single commit
    def retrieve_commit_comments(user, repo, sha)
      retrieved_comments = paged_api_request(ghurl "repos/#{user}/#{repo}/commits/#{sha}/comments")

      retrieved_comments.each { |x|
        x['repo'] = repo
        x['user'] = user
        x['commit_id'] = sha

        if persister.find(:commit_comments, {'repo' => repo,
                                              'user' => user,
                                              'id' => x['id']}).empty?
          persister.store(:commit_comments, x)
        end
      }
      persister.find(:commit_comments, {'commit_id' => sha}) #.map{|x| x[ext_uniq] = x['_id']; x}
    end

    # Retrieve a single comment
    def retrieve_commit_comment(user, repo, id)

      comment = persister.find(:commit_comments, {'repo' => repo,
                                                   'user' => user,
                                                   'id' => id}).first
      if comment.nil?
        r = api_request(ghurl "repos/#{user}/#{repo}/comments/#{id}")

        if r.empty?
          debug "Retriever: Commit comment #{id} deleted"
          return
        end

        r['repo'] = repo
        r['user'] = user
        persister.store(:commit_comments, r)
        info "Retriever: Added commit comment #{r['commit_id']} -> #{r['id']}"
        r[ext_uniq] = r['_id']
        r
      else
        debug "Retriever: Commit comment #{comment['commit_id']} -> #{comment['id']} exists"
        comment
      end
    end

    # Retrieve all collaborators for a repository
    def retrieve_repo_collaborators(user, repo)
      repo_bound_items(user, repo, :repo_collaborators,
                       "repos/#{user}/#{repo}/collaborators",
                       {'repo' => repo, 'owner' => user},
                       'login')
    end

    # Retrieve a single repository collaborator
    def retrieve_repo_collaborator(user, repo, new_member)
      repo_bound_item(user, repo, new_member, :repo_collaborators,
                      "repos/#{user}/#{repo}/collaborators",
                      {'repo' => repo, 'owner' => user},
                      'login')
    end

    # Retrieve all watchers for a repository
    def retrieve_watchers(user, repo)
      repo_bound_items(user, repo, :watchers,
                       "repos/#{user}/#{repo}/watchers",
                       {'repo' => repo, 'owner' => user},
                       'login')
    end

    # Retrieve a single watcher for a repositry
    def retrieve_watcher(user, repo, watcher)
      repo_bound_item(user, repo, watcher, :watchers,
                      "repos/#{user}/#{repo}/watchers",
                      {'repo' => repo, 'owner' => user},
                      'login')
    end

    def retrieve_pull_requests(user, repo)
      open = "repos/#{user}/#{repo}/pulls"
      closed = "repos/#{user}/#{repo}/pulls?state=closed"
      repo_bound_items(user, repo, :pull_requests,
                       [open, closed],
                       {'repo' => repo, 'owner' => user},
                       'number')
    end

    def retrieve_pull_request(user, repo, pullreq_id)
      open = "repos/#{user}/#{repo}/pulls"
      closed = "repos/#{user}/#{repo}/pulls?state=closed"
      repo_bound_item(user, repo, pullreq_id, :pull_requests,
                      [open, closed],
                      {'repo' => repo, 'owner' => user,
                       'number' => pullreq_id},
                      'number')
    end

    # Get current Github events
    def get_events
      api_request "https://api.github.com/events"
    end

    private

    def repo_bound_items(user, repo, entity, urls, selector, descriminator)
      stored_items = persister.find(entity, selector)

      items = if urls.class == Array
                urls.map { |url| paged_api_request(ghurl url) }.flatten
              else
                paged_api_request(ghurl urls)
              end

      items.each do |x|
        x['repo'] = repo
        x['owner'] = user

        exists = !stored_items.find { |f|
          f[descriminator] == x[descriminator]
        }.nil?

        if not exists
          persister.store(entity, x)
          info "Retriever: Added #{entity} #{repo} -> #{x[descriminator]}"
        else
          debug "Retriever: #{entity} #{repo} -> #{x[descriminator]} exists"
        end
      end
      persister.find(entity, selector)
    end

    def repo_bound_item(user, repo, item_id, entity, url, selector, descriminator)
      selector.merge!({descriminator => item_id})
      stored_item = persister.find(entity, selector)

      if stored_item.empty?
        repo_bound_items(user, repo, entity, url, selector, descriminator).\
                        find{|x| x[descriminator] == item_id}
      else
        stored_item.first
      end
    end

    def ghurl(path)
      config(:mirror_urlbase) + path
    end

  end
end
