# Jenkins Github Branch Status Updater

This plugin:

* Let's you use Hubot to trigger parameterized builds
  based on a git branch
  tied to a github issue or pull request.
  Eg. `@HubotBotson ci issue 1235`
* Tracks the status of those builds
  and updates the pull request status
  using Github's repo status API.
  If you've used Travis-CI,
  you'll recognize this.
* This plugin is downstream-job aware slash dependent!
  It encourages very-quick root jobs
  that then spawn off multiple downstream jobs
  to do most of the actual heavy-lifting.

## Assumptions about your jobs

### `GIT_BRANCH` parameter

Your root job and downstream jobs
all take the parameter `GIT_BRANCH`
and know how to build a job for that pull request.

## Required Environment Variables

You'll need to configure these variables
using `$ heroku config:set FOO=BAR`
in order to use this plugin.

### HUBOT_GITHUB_REPO

The Github repository qualified name,
e.g. **PolicyStat/PolicyStat**

### `HUBOT_GITHUB_TOKEN`

The auth token from Github's account settings

### `HUBOT_JENKINS_AUTH`

The basic auth for the Hubot user,
e.g. **user:password**

### `HUBOT_JENKINS_URL`

The domain for our Jenkins site,

e.g. **http://jenkins.pstattest.com**

### Google Compute Engine configuration

Jenkins workers are spun up on Google Compute Engine
in response to request to run tests against an issue.

To obtain credentials,
create a `Service Account`
and download the `JSON key` file.
See the [gcloud-node Authorization docs](https://googlecloudplatform.github.io/gcloud-node/#/authorization).

#### `GCLOUD_PROJECT`

The Google Compute Engine projectID
under which your Jenkins workers
will be created.

#### `GCE_CREDENTIALS_CLIENT_EMAIL`

This is the `client_email` value
from the JSON key file.

#### `GCE_CREDENTIALS_PRIVATE_KEY`

This is the `private_key` value
from the JSON key file.
In the JSON file,
newlines will be encoded as `\n`.
To translate these to real newlines for the shell variable,
perform a find/replace in your editor
so that they're actually on new lines.
Then,
wrap the contents in quotes on the shell.

e.g.
```
heroku config:set GCE_CREDENTIALS_PRIVATE_KEY="-----BEGIN PRIVATE KEY-----
foobarbaz
sekritrandomcharacters
-----END PRIVATE KEY-----
"
```

#### `GCE_DISK_SOURCE_IMAGE`

The name of the disk image you'd like to use
as your boot disk.

## Optional Environment Variables

### `JENKINS_ROOT_JOB_NAME`

Name of the root job to build, when asked.

Default: `pstat_ticket`

### `JENKINS_NOTIFICATION_ENDPOINT`

Hubot listens at this endpoint for any new build statuses,

Default: **/hubot/build-status**

### `JENKINS_ROOT_JOB_NOTIFICATION_ENDPOINT`

Hubot listens at this endpoint for build status from the root job.

Default: **/hubot/root-build-status**

### Google Compute Engine configurations

#### `GCE_MACHINE_TYPE`

The name of the [machine type](https://cloud.google.com/compute/docs/machine-types)
your Jenkins workers will use.

Default: `n1-highcpu-2`

#### `GCE_ZONE_NAMES

A space-separated list
(e.g. `us-east1-b us-east4-a us-west1-b`)
of GCE region-qualified zone names
inside which GCE instances will be launched.

Default: Required

#### `GCE_COMPUTE_ENGINE_SERVICE_ACCOUNT_EMAIL`

This is the [compute engine service account name](https://cloud.google.com/compute/docs/authentication#serviceaccountname)
attached to your project.
It's the `Compute Engine service account`
on the `Permissions` tab.

If this is provided,
your VMs will have permissions required
to delete themselves.
This allows them to be self-managing
via an on-shutdown script
so that they won't stick around in the `Stopped` state.

Default: None

Example: `xxxxxxxxx@project.gserviceaccount.com`

## Jenkins Configuration

The Jenkins [Notification Plugin](https://wiki.jenkins-ci.org/display/JENKINS/Notification+Plugin)
is necessary to keep hubot in the loop on your Jenkins job statuses.
For both your main job and its downstream jobs
you'll need to add a `Job Notifications` - `Notification Endpoint`.

* The URL needs to be the **full URL**
* Format: JSON
* Protocol: HTTP

### Root/Main Job

For the root/main job that spawns downstream jobs,
use the full url including the `JENKINS_ROOT_JOB_NOTIFICATION_ENDPOINT`:

`http://pstat-hubot.herokuapp.com/hubot/root-build-status`

The URL path must match `JENKINS_ROOT_JOB_NOTIFICATION_ENDPOINT`.

### Downstream jobs

For downstream jobs,
use the full url including the `JENKINS_NOTIFICATION_ENDPOINT`:

`http://pstat-hubot.herokuapp.com/hubot/build-status`

The URL path must match `JENKINS_NOTIFICATION_ENDPOINT`.

## For Contributors: Rough Outline of Flow

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

## Addendum: Jenkins Notification Plugin

Documentation to aid in contributing to this plugin.

There doesn't seem to be much documentation
for the Jenkins Notification Plugin so this section
will cover some of the important parts.

The plugin sends a notification in the following JSON format:

    {
      "name":"pstat_selenium_1",
      "url":"job/pstat_ticket_selenium_1/844/",
      "build": {
        "number":"844",
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

### Phases

#### STARTED

The `STARTED` phase is
triggered when the build is
actively running
(not just when it's in the queue).

Only the root job uses the `STARTED` phase,
just as a trigger to grab the commit SHA
and the number of downstream jobs.

### FINISHED

The `FINISHED` phase is
triggered when the build finishes running.

The status updater uses this phase
to update the Github branch status
once all builds for an upstream build have finished.

### COMPLETED

It's not clear what this phase does
but it seems to be triggered after the finished phase.

The status updater doesn't use this phase.

### Statuses

#### FAILURE

At least one test in the build failed.

#### SUCCESS

All tests passed.

#### ABORTED

The build run was ended prematurely.
