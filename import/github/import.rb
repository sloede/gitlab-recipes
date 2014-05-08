#!/usr/bin/env ruby

# Community contributed script to import from GitHub to GitLab
# It imports repositories, issues and the wiki's.
# This script is not maintained, please send merge requests to improve it, do
# not file bugs.  The issue import might concatenate all comments of an issue
# into one, if so feel free to fix this.

require 'bundler/setup'
require 'octokit'
require 'optparse'
require 'git'
require 'gitlab'
require 'pp'

#deal with options from cli, like username and pw
options = {:usr => nil,
           :pw => nil,
           :api => 'https://github.com/api/v3',
           :web => 'https://github.com/',
           :enterprise => false,
           :space => nil,
           :gitlab_api => 'http://gitlab.github.com/api/v3',
           :gitlab_token => 'secret',
           :repo => nil
           }
optparse = OptionParser.new do |opts|
  opts.on('-u', '--user USER',
          'User to connect to GitHub with (default: #{options[:usr]})') do |u|
    options[:usr] = u
  end
  opts.on('-p', '--pw PASSWORD',
          'Password for user to connect to GitHub with (default: #{options[:pw]})') do |p|
    options[:pw] = p
  end
  opts.on('-a', '--api',
          'API endpoint for GitHub (default: #{options[:api]})') do |a|
    options[:api] = a
  end
  opts.on('-w', '--web',
          'Web endpoint for GitHub (default: #{options[:web]})') do |w|
    options[:web] = w
  end
  opts.on('-s', '--space SPACE',
          'The space to import repositories from (user or organization) (default: #{options[:enterprise]})') do |s|
    options[:space] = s
  end
  opts.on('-r', '--repo REPO',
          'The repository to import (default: all)') do |r|
    options[:repo] = r
  end
  opts.on('-h', '--help',
          'Display this screen') do
    puts opts
    exit
  end
end

optparse.parse!
if options[:usr].nil? or options[:pw].nil?
  puts "Missing parameter (username and/or password)"
  puts options
  exit
end

#setup octokit to deal with GitHub enterprise
if options[:enterprise]
  Octokit.configure do |c|
    c.api_endpoint = options[:api]
    c.web_endpoint = options[:web]
  end
end

#set the gitlab options
Gitlab.configure do |c|
  c.endpoint = options[:gitlab_api]
  c.private_token = options[:gitlab_token]
end

#setup the clients
gh_client = Octokit::Client.new(:login => options[:usr],
                                :password => options[:pw])
gl_client = Gitlab.client()

# Create temporary directory
Dir.mktmpdir do |tmpdir|
  # Create subdirectories
  clonedir = "#{tmpdir}/clones"
  junkdir = "#{tmpdir}/junk"
  Dir.mkdir(clonedir)
  Dir.mkdir(junkdir)

  # Get all of the repos that are in the specified space (user or org)
  gh_repos = gh_client.repositories(options[:space])
  gh_repos.each do |gh_r|
    #
    # If repo was specified on command line, do not process any other repos
    #
    if (!options[:repo].nil? and gh_r.name != options[:repo])
      puts "Skipping #{gh_r.name}."
      next
    end
    print "Importing #{gh_r.name}... "

    #
    ## clone the repo from the GitHub server
    #
    git_repo = nil
    if File.directory?("#{clonedir}/#{gh_r.name}")
      git_repo = Git.open("#{clonedir}/#{gh_r.name}")
      git_repo.pull
    else
      git_repo = Git.clone(gh_r.git_url, gh_r.name, :path => clonedir)
    end

    #
    ## Push the cloned repo to gitlab
    #
    project_list = []

    push_group = nil
    #I should be able to search for a group by name
    gl_client.groups.each do |g|
      if g.name == options[:space]
        push_group = g
      end
    end

    #if the group wasn't found, create it
    if push_group.nil?
      push_group = gl_client.create_group(options[:space], options[:space])
    end

    #edge case, gitlab didn't like names that didn't start with an alpha.
    #Can't remember how I ran into this.
    name = gh_r.name
    if gh_r.name !~ /^[a-zA-Z]/
      name = "gh-#{gh_r.name}"
    end

    #create and push the project to GitLab
    new_project = gl_client.create_project(name)
    git_repo.add_remote("gitlab", new_project.ssh_url_to_repo)
    git_repo.push('gitlab')

    #
    ## Look for issues in GitHub for this project and push them to GitLab
    ## I wish the GitLab API let me create comments for issues. Oh well,
    ## smashing it all into the body of the issue.
    #
    if gh_r.has_issues
      issues = gh_client.issues(gh_r.full_name)
      issues.each do |i|
        comments = gh_client.issue_comments(gh_r.full_name, i['number'])
        body = i.body
        if comments.any?
          body += "\n\n\nComments from GitHub import:\n"
          comments.each do |c|
            body += "\n\n#{c.body}\nBy #{c.user.login} on #{c.created_at}"
          end
        end
        gl_issue = gl_client.create_issue(new_project.id, i.title, :description => body)
      end
    end

    #
    ## Look for wiki pages for this repo in GitHub and migrate them to GitLab
    #
    if gh_r.has_wiki
      #this is dumb. The only way to know if a repo has a wiki is to attempt to
      #clone it and then ignore failure if it doesn't have one
      begin
        gh_wiki_url = gh_r.git_url.gsub(/\.git/, ".wiki.git")
        wiki_name = gh_r.name + '.wiki'
        wiki_repo = Git.clone(gh_wiki_url, wiki_name, :path => tmpdir)

        #this is a pain, have to visit the wiki page on the web ui before being
        #able to work with it as a git repo
        `wget -q --save-cookies #{junkdir}/gl_login.txt -P #{junkdir} --post-data "username=#{options[:usr]}&password=#{options[:pw]}" gitlab.example.com/users/auth/ldap/callback`
        `wget -q --load-cookies #{junkdir}/gl_login.txt -P #{junkdir} -p #{new_project.web_url}/wikis/home`
        `rm -fr #{junkdir}/*`

        gl_wiki_url = new_project.ssh_url_to_repo.gsub(/\.git/, ".wiki.git")
        wiki_repo.add_remote('gitlab', gl_wiki_url)
        wiki_repo.push('gitlab')
      rescue
        # Nothing to do (i.e. cloning of the wiki failed so we can skip it)
      end
    end

    # change the owner of this new project to the group we found it in
    gl_client.transfer_project_to_group(push_group.id, new_project.id)

    # Inform user that we are finished with the current repo
    puts "done."
  end
end
