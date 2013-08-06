# Jenkins Github Branch Status Updater

When a build is triggered through Hubot, 
we update that branch's status to PENDING via the Github API. 
Jenkins sends notifications to Hubot 
through the Jenkins Notification Plugin 
with status updates. 
Redis-brain keeps track of the statuses 
in the Redis To Go add on that comes with Heroku. 
When all builds have completed for a branch, 
we update the Github branch's status 
to show success if it was successful 
or a list of the failed builds 
if any of the builds failed. 

When the branch's status is initially set to PENDING,
the `target_url` is generated using the Jenkins response 
to point to the upstream build status.
When the branch's status is set to SUCCESS or FAILURE,
the `target_url` is generated using `HUBOT_JENKINS_URL` 
and the `SOURCE_BUILD_NUMBER` from the Jenkins Notification Plugin.

## Environment Variable
### HUBOT_GITHUB_REPO
The Github repository qualified name, 
e.g. 'PolicyStat/PolicyStat'

### HUBOT_GITHUB_TOKEN
The auth token from Github's account settings

### HUBOT_JENKINS_AUTH
The basic auth for the Hubot user, 
e.g. 'user:password'

### HUBOT_JENKINS_URL
The domain for our Jenkins site, 
e.g. 'http://jenkins.pstattest.com'

### JENKINS_NOTIFICATION_ENDPOINT
The endpoint that the Jenkins Notificatin Plugin sends status data. 
Hubot listens at this endpoint for any new build statuses, 
e.g. '/hubot/build-status'

#### Configuring Jenkins
The notification endpoint will need to be configured 
for each project that you want to track statuses for.
The URL needs to be the full path to the Hubot endpoint, 
e.g. 'http://pstat-hubot.herokuapp.com/hubot/build-status'


### JENKINS_NUM_PROJECTS
Controls how many jobs are needed 
to trigger a 'finished' update 
to the Github branch status.

## Jenkins Notification Plugin
There doesn't seem to be much documentation 
for the Jenkins Notification Plugin so this section 
will cover some of the important parts.

The plugin sends a notification in the following JSON format:

    {"name":"pstat_selenium_1",
     "url":"job/pstat_ticket_selenium_1/844/",
     "build":{
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
Triggered when the build is actively running (not just when it's in the queue).

The Jenkins Github status updater doesn't actually rely on the 'STARTED' phase.
Instead, when a build is triggered using Hubot, 
the Github branch status is immediately set to pending.

#### FINISHED
Triggered when the build finishes running.

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