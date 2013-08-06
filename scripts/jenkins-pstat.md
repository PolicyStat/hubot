# Jenkins Github Branch Status Updater

When a build is triggered through Hubot, 
we update that branch's status to PENDING via the
[Github API](http://developer.github.com/v3/repos/statuses). 
When a Jenkins build finishes,
the [Jenkins Notification Plugin](https://wiki.jenkins-ci.org/display/JENKINS/Notification+Plugin)
([github](https://github.com/jenkinsci/notification-plugin))
communicates with hubot
and hubot will update the branch status
only when all of the downstream builds have completed.
The individual build statuses are tracked using
[redis-brain](https://github.com/github/hubot-scripts/blob/master/src/scripts/redis-brain.coffee)
which interfaces with the 
[Redis To Go](https://addons.heroku.com/redistogo) add-on that comes with Heroku.

When the branch's status is initially set to PENDING,
the `target_url` is generated using the Jenkins response 
to point to the upstream build status.
When the branch's status is set to SUCCESS or FAILURE,
the `target_url` is generated using `HUBOT_JENKINS_URL` 
and the `SOURCE_BUILD_NUMBER` from the Jenkins Notification Plugin.

## Environment Variable
### HUBOT_GITHUB_REPO
The Github repository qualified name, 
e.g. **PolicyStat/PolicyStat**

### HUBOT_GITHUB_TOKEN
The auth token from Github's account settings

### HUBOT_JENKINS_AUTH
The basic auth for the Hubot user, 
e.g. **user:password**

### HUBOT_JENKINS_URL
The domain for our Jenkins site, 
e.g. **http://jenkins.pstattest.com**

### JENKINS_NOTIFICATION_ENDPOINT
Hubot listens at this endpoint for any new build statuses, 
e.g. **/hubot/build-status**

#### A note on configuring Jenkins
The notification endpoint will need to be configured 
for each project that you want to track statuses for.
The URL needs to be the full path to the Hubot endpoint, 
e.g. **http://pstat-hubot.herokuapp.com/hubot/build-status**

The URL path must match `JENKINS_NOTIFICATION_ENDPOINT`.

### JENKINS_NUM_PROJECTS
Controls how many jobs are needed 
to trigger a *finished* update 
to the Github branch status.
Generally,
this value will be 1,
unless Jenkins is configured to
spawn multiple build jobs for a single run.
In that scenario,
this number should be set to
the number of jobs spawned.

## Jenkins Notification Plugin
There doesn't seem to be much documentation 
for the Jenkins Notification Plugin so this section 
will cover some of the important parts.

The plugin sends a notification in the following JSON format:

    {
      "name":"pstat_selenium_1",
      "url":"job/pstat_ticket_selenium_1/844/",
      "build": {
        "number":844,
        "phase":"FINISHED",
        "status":"FAILURE",
        "url":"job/pstat_ticket_selenium_1/844/",
        "full_url":"http://jenkins.pstattest.com/job/pstat_ticket_selenium_1/844/",
        "parameters":{
          "ISSUE":"1096",
          "SOURCE_BUILD_NUMBER": "904"
        }
    	 }
    }

### Phase
#### STARTED
The **STARTED** phase is
triggered when the build is
actively running
(not just when it's in the queue).

The Jenkins Github status updater currently doesn't use the **STARTED** phase.
Instead,
when a build is triggered using Hubot, 
the Github branch status is
immediately set to pending.

#### FINISHED
The **FINISHED** phase is
triggered when the build finishes running.

The status updater uses this phase 
to update the Github branch status 
once all builds for an upstream build have finished.

#### COMPLETED
It's not clear what this phase does
but it seems to be triggered after the finished phase.

The status updater doesn't use this phase.

### Status
#### FAILURE
At least one test in the build failed.

#### SUCCESS
All tests passed.

#### ABORTED
The build run was ended prematurely.
