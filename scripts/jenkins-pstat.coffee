# Description:
#   Interact with your Jenkins CI server
#
# Configuration:
#   HUBOT_JENKINS_URL
#   HUBOT_JENKINS_AUTH - Optional; for authenticating the trigger request (user:password)
#
# Commands:
#   hubot ci issue <issue_number> - builds the pstat_ticket job with the corresponding issue_<issue_number> branch
#   hubot ci workers <N> - Launch N number of jenkins workers. N is optional and defaults to 1. Use "max" to use the default maximum number of workers.

# GCLOUD_PROJECT is passed in automatically from the env
moment = require('moment')
sprintf = require('sprintf-js').sprintf
URL = require('url-parse')

github = {}
gce = {}

CI_ENABLED = process.env.CI_ENABLED == 'true'

HUBOT_JENKINS_URL = process.env.HUBOT_JENKINS_URL
HUBOT_JENKINS_AUTH = process.env.HUBOT_JENKINS_AUTH
HUBOT_GITHUB_REPO = process.env.HUBOT_GITHUB_REPO

JENKINS_JNLP_CREDENTIALS = process.env.JENKINS_JNLP_CREDENTIALS
JENKINS_AGENT_LABEL = process.env.JENKINS_AGENT_LABEL
JENKINS_AGENT_AWS_ACCESS_KEY_ID = process.env.JENKINS_AGENT_AWS_ACCESS_KEY_ID
JENKINS_AGENT_AWS_SECRET_ACCESS_KEY = process.env.JENKINS_AGENT_AWS_SECRET_ACCESS_KEY

JENKINS_NOTIFICATION_ENDPOINT = process.env.JENKINS_NOTIFICATION_ENDPOINT or "/hubot/build-status"
JENKINS_ROOT_JOB_NOTIFICATION_ENDPOINT = process.env.JENKINS_ROOT_JOB_NOTIFICATION_ENDPOINT or "/hubot/root-build-status"
JENKINS_ROOT_JOB_NAME = process.env.JENKINS_ROOT_JOB_NAME or "pstat_ticket"

# These values can be obtained from the JSON key file you download when creating
# a service account.
# Required GCE configs
GCE_CREDENTIALS_CLIENT_EMAIL = process.env.GCE_CREDENTIALS_CLIENT_EMAIL
GCE_CREDENTIALS_PRIVATE_KEY = process.env.GCE_CREDENTIALS_PRIVATE_KEY
GCE_DISK_SOURCE_IMAGE = process.env.GCE_DISK_SOURCE_IMAGE
GCE_ZONE_NAMES = process.env.GCE_ZONE_NAMES.split(' ')
# Optional GCE configs
GCE_MACHINE_TYPE = process.env.GCE_MACHINE_TYPE or 'n1-highcpu-2'

GCE_COMPUTE_ENGINE_SERVICE_ACCOUNT_EMAIL = process.env.GCE_COMPUTE_ENGINE_SERVICE_ACCOUNT_EMAIL or ''
DISK_TYPE_TPL = 'zones/%s/diskTypes/pd-ssd'

BUILD_DATA = {
  'COMMIT_SHA': 'commit_SHA',
  'GIT_BRANCH': 'git_branch',
  'ROOT_JOB_NAME': 'root_job_name',
  'ROOT_BUILD_NUMBER': 'root_build_number',
  'JOBS': 'jobs',
}
JENKINS_BUILD_STATUS = {
  'FAILURE': 'FAILURE',
  'SUCCESS': 'SUCCESS',
  'ABORTED': 'ABORTED',
}
JENKINS_BUILD_PHASE = {
  'COMPLETED': 'COMPLETED',
  'STARTED': 'STARTED',
}
GITHUB_REPO_STATUS = {
  'PENDING': 'pending',
  'FAILURE': 'failure',
  'SUCCESS': 'success',
}

jenkins_launch_workers = ({num_workers, force, image, label, jenkins_url}) ->
  console.log "jenkins_launch_workers(#{num_workers},#{force},#{image},#{label},#{jenkins_url})"

  instances = []
  zoneResultsCount = 0

  _aggregateVMsAcrossZones = (err, vms) ->
    if err
      console.log 'Error retrieving current VM list', err
      return
    zoneResultsCount += 1
    instances = instances.concat(vms)
    remaining = GCE_ZONE_NAMES.length - zoneResultsCount
    if remaining <= 0
      _createWorkers()

  _createWorkers = () ->
    instanceCountByZone = _getInstanceCountByZone(instances)

    numRunningInstances = 0
    for zoneName of instanceCountByZone
      numRunningInstances += instanceCountByZone[zoneName]

    if force isnt true and numRunningInstances >= num_workers
      console.log "The requested number of workers #{num_workers} are already running"
      return

    workerNumbersByZone = _distributeWorkersAcrossZones(num_workers, instanceCountByZone)
    timestamp = moment().format 'MMDD-HHmmss-SS'  # e.g. 0901-134102-09
    for zoneName of workerNumbersByZone
      _createWorkersInZone(
        workerIndexes: workerNumbersByZone[zoneName]
        zoneName: zoneName
        timestamp: timestamp
        image: image
        label: label
        jenkins_url: jenkins_url
      )

  for zoneName in GCE_ZONE_NAMES
    zone = gce.zone(zoneName)
    # Determine which zones are busy, based on which currently have VMs,
    # so that we can spread our workers across zones.
    # This minimizes the likelihood of all of our workers being prempted at the same time.
    zone.getVMs(_aggregateVMsAcrossZones)

_getInstanceCountByZone = (instances) ->
  instanceCountByZone = {}
  for zoneName in GCE_ZONE_NAMES
    instanceCountByZone[zoneName] = 0

  for instance in instances
    # Only STAGING and RUNNING statuses indicate that there are available resources in a zone
    # see: https://cloud.google.com/compute/docs/instances/#checkmachinestatus
    status = instance.metadata.status
    if status in ['STAGING', 'RUNNING']
        instanceCountByZone[instance.zone.name] += 1
    else if status == 'TERMINATED'
      console.log "Deleting #{instance.name} with status #{status}"
      instance.delete()
    else
      console.log "Ignoring #{instance.name} with status #{status}"
  instanceCountByZone

_distributeWorkersAcrossZones = (num_workers, instanceCountByZone) ->
  maxWorkersPerZone = Math.ceil(num_workers / GCE_ZONE_NAMES.length)
  workerIndexes = [0...num_workers]

  # Distribute the indexes evenly across the zones.
  # The last zones will get 1 less if it doesn't work out evenly.
  # In the case of very low numbers (e.g. 5 nodes in 4 zones),
  # it's possible for zones to get no indexes.
  i = 0
  workerNumbersByZone = {}
  for zoneName of instanceCountByZone
    workerNumbersByZone[zoneName] = workerIndexes[i .. (i+maxWorkersPerZone)-1]
    i += maxWorkersPerZone
  workerNumbersByZone

_createWorkersInZone = ({workerIndexes, zoneName, timestamp, image, label, jenkins_url}) ->
  desiredMachineCount = workerIndexes.length
  if desiredMachineCount == 0
    return

  zone = gce.zone(zoneName)

  vmConfig = {
    machineType: GCE_MACHINE_TYPE
    disks: [
      {
        boot: true
        initializeParams: {
          sourceImage: "global/images/#{ image }"
          diskType: 'zones/us-central1-a/diskTypes/pd-ssd'
        }
        autoDelete: true
      }
    ]
    networkInterfaces: [
      {
        network: 'global/networks/default'
        accessConfigs: [
          {
            type: 'ONE_TO_ONE_NAT'
            name: 'External NAT'
          }
        ]
      }
    ]
    scheduling: {
      onHostMaintenance: 'TERMINATE'
      automaticRestart: false
      preemptible: true
    }
    metadata: {
      items: [
        {
          key: "JENKINS_URL"
          value: jenkins_url
        },
        {
          key: "JENKINS_AGENT_LABEL"
          value: label
        },
        {
          key: "JNLP_CREDENTIALS"
          value: JENKINS_JNLP_CREDENTIALS
        },
        {
          key: "AWS_ACCESS_KEY_ID"
          value: JENKINS_AGENT_AWS_ACCESS_KEY_ID
        },
        {
          key: "AWS_SECRET_ACCESS_KEY"
          value: JENKINS_AGENT_AWS_SECRET_ACCESS_KEY
        },
      ]
    }
  }
  console.log "Launching #{desiredMachineCount} machines in zone #{zone.name}"
  # The diskType config must be zone-specific
  vmConfig.disks[0].initializeParams.diskType = sprintf(DISK_TYPE_TPL, zone.name)
  if GCE_COMPUTE_ENGINE_SERVICE_ACCOUNT_EMAIL.length > 0
    vmConfig['serviceAccounts'] = [ {
      'email': GCE_COMPUTE_ENGINE_SERVICE_ACCOUNT_EMAIL
      'scopes': [ 'https://www.googleapis.com/auth/compute' ]
    } ]
  i = 0
  while i < desiredMachineCount
    vmName = sprintf('worker-%s-%02d-%s', timestamp, workerIndexes[i], zoneName)
    console.log "Creating VM: #{vmName}"
    zone.createVM vmName, vmConfig, (err, vm, operation, response) ->
      if err
        console.log 'Error creating VM'
        console.log err
        return
      console.log "VM creation call succeeded for: #{vm.name} with #{operation.name}"
    i++


cache_set = (robot, namespace, key, value) ->
  robot.brain.set("#{namespace}-#{key}", value)

cache_get = (robot, namespace, key) ->
  return robot.brain.get("#{namespace}-#{key}")

jenkins_root_job_completed_successfully = (robot, job_name, build) ->
  console.log "jenkins_root_job_completed_successfully(#{job_name})"
  git_branch = build.parameters.GIT_BRANCH
  jenkins_host = new URL(build.full_url).origin

  # build.notes has UUID, if set
  build_id = build.notes or build.number
  worker_image = build.parameters.WORKER_IMAGE or GCE_DISK_SOURCE_IMAGE
  worker_label = build.parameters.WORKER_LABEL or JENKINS_AGENT_LABEL

  console.log "branch:#{git_branch} id:#{build_id} jenkins:#{jenkins_host}"

  url = "#{jenkins_host}/job/#{job_name}/api/json?tree=downstreamProjects[name]"
  req = robot.http(url)

  if HUBOT_JENKINS_AUTH
    auth = new Buffer(HUBOT_JENKINS_AUTH).toString('base64')
    req.headers Authorization: "Basic #{auth}"

  req.get() (err, res, body) ->
    if err
      console.log "Failed to get #{url}: #{err}"
    else if res.statusCode != 200
      console.log "Failed to get #{url}: #{res.statusCode}"
    else if res.statusCode == 200
      json = JSON.parse(body)
      cache_set(robot, build_id, BUILD_DATA.ROOT_JOB_NAME, job_name)
      cache_set(robot, build_id, BUILD_DATA.ROOT_BUILD_NUMBER, build.number)
      cache_set(robot, build_id, BUILD_DATA.JOBS, json.downstreamProjects)

      # Initialize all the downstream jobs to FAILURE
      for downstream_job in json.downstreamProjects
        cache_set(robot, build_id, downstream_job.name, JENKINS_BUILD_STATUS.FAILURE)

      num_workers = json.downstreamProjects.length

      jenkins_launch_workers(
        num_workers: num_workers
        force: false
        image: worker_image
        label: worker_label
        jenkins_url: jenkins_host
      )

jenkins_job_completed = (robot, job_name, build) ->
  build_id = build.parameters.ROOT_JOB_UUID ? build.parameters.ROOT_BUILD_NUMBER
  console.log "jenkins_job_completed(#{job_name},#{build.status},build_id=#{build_id})"

  jenkins_host = new URL(build.full_url).origin

  cache_set(build_id, downstream_job.name, build.status)

  downstream_jobs = cache_get(robot, build_id, BUILD_DATA.JOBS)
  root_job_name = cache_get(build_id, BUILD_DATA.ROOT_JOB_NAME)
  root_build_number = cache_get(build_id, BUILD_DATA.ROOT_BUILD_NUMBER)

  failed_count = 0
  passed_count = 0
  all_success = true
  for job_name in downstream_jobs
    job_status = cache_get(build_id, job_name)
    if job_status == JENKINS_BUILD_STATUS.SUCCESS
      passed_count += 1
    else
      all_success = false
      failed_count += 1

  console.log "#{build_id} Passed:#{passed_count} Failed:#{failed_count}"

  if all_success
    status_description = "#{passed_count} jobs completed successfully"
    github_status = GITHUB_REPO_STATUS.SUCCESS
  else
    status_description = "#{failed_count} jobs have failed (#{passed_count} completed successfully)"
    github_status = GITHUB_REPO_STATUS.FAILURE

  target_url = "#{jenkins_host}/job/#{root_job_name}/#{root_build_number}"

  git_branch = build.parameters.GIT_BRANCH
  commit_sha = build.parameters.GIT_COMMIT
  console.log "#{build_id} updating github branch status: #{git_branch} #{commit_sha} #{github_status}"
  update_github_commit_status(
    commit_sha: commit_sha
    status: github_status
    target_url: target_url
    description: status_description
  )

update_github_commit_status = ({commit_sha, status, target_url, description}) ->
  repo = github.qualified_repo(HUBOT_GITHUB_REPO)
  data = (
    state: status
    target_url: target_url
    description: description
  )
  callback_func = ->
  github.post("repos/#{repo}/statuses/#{commit_sha}", data, callback_func)

_parse_ci_option_string = (raw_options) ->
  raw_options = raw_options or ''

  options = new ->
    for param in raw_options.split(',')
      params = param.split('=')
      @[params[0]] = params[1]
    this

  source_image = GCE_DISK_SOURCE_IMAGE
  label = JENKINS_AGENT_LABEL
  jenkins_url = HUBOT_JENKINS_URL

  if options?
    if options.image?
      source_image = options.image
    if options.label?
      label = options.label
    if options.url?
      jenkins_url = options.url

  return (
    image: source_image
    label: label
    jenkins_url: jenkins_url
  )

handle_command_ci_workers = (msg) ->
  if CI_ENABLED is false
    msg.send "CI system is currently disabled"
    return

  num_workers = msg.match[1] or 1
  options = _parse_ci_option_string(msg.match[2])

  jenkins_launch_workers(
    num_workers: num_workers
    force: true
    image: options.image
    label: options.label
    jenkins_url: options.jenkins_url
  )
  msg.send "Launching #{num_workers} Jenkins workers"

handle_command_ci_issue = (robot, msg) ->
  if CI_ENABLED is false
    msg.send "CI system is currently disabled"
    return

  baseUrl = HUBOT_JENKINS_URL
  issue = msg.match[1]
  branch = "issue_#{issue}"
  channelId = msg.message.rawMessage.channel

  url = "#{baseUrl}/job/#{JENKINS_ROOT_JOB_NAME}/buildWithParameters?GIT_BRANCH=#{branch}"
  req = msg.http(url)
  if HUBOT_JENKINS_AUTH
    auth = new Buffer(HUBOT_JENKINS_AUTH).toString('base64')
    req.headers Authorization: "Basic #{auth}"

  req.header('Content-Length', 0)
  req.post() (err, res, body) ->
      if err
        message = "Jenkins reported an error: #{err}"
      else if res.statusCode == 201
        message = "#{JENKINS_ROOT_JOB_NAME} #{branch}: Queued"
        robot.brain.set(branch, channelId)
      else
        message = "Jenkins responded with status code #{res.statusCode}"
      robot.messageRoom(channelId, message)


module.exports = (robot) ->
  github = require("githubot")(robot)
  gcloud = require('gcloud')
  gce = gcloud.compute(
    credentials:
      client_email: GCE_CREDENTIALS_CLIENT_EMAIL
      private_key: GCE_CREDENTIALS_PRIVATE_KEY
  )

  github.handleErrors (response) ->
    console.log "Oh noes! A github request returned #{response.statusCode}"
    console.log "and error message: #{response.error}"
    console.log "and body: #{response.body}"

  robot.respond /message test/i, (msg) ->
    channelId = msg.message.rawMessage.channel
    robot.messageRoom channelId, "pong - channel ID is #{channelId}"

  robot.respond /ci issue ([\d_]+)/i, (msg) ->
    handle_command_ci_issue(robot, msg)

  robot.respond /ci workers ?(\d+)? ?([\S]*)/i, (msg) ->
    handle_command_ci_workers(msg)

  robot.router.post JENKINS_NOTIFICATION_ENDPOINT, (req, res) ->
    message = req.body
    if message.build.phase is JENKINS_BUILD_PHASE.COMPLETED
      jenkins_job_completed(robot, message.name, message.build)
    res.end "ok"

  robot.router.post JENKINS_ROOT_JOB_NOTIFICATION_ENDPOINT, (req, res) ->
    jenkins_job = req.body
    jenkins_build = jenkins_job.build
    root_job_name = jenkins_job.name
    full_url = jenkins_build.full_url
    git_branch = jenkins_build.parameters.GIT_BRANCH
    slack_room = robot.brain.get(git_branch)

    if jenkins_job.build.phase is JENKINS_BUILD_PHASE.STARTED
      if slack_room
        robot.messageRoom(slack_room, "<#{full_url}|#{root_job_name}/#{git_branch}>: Started")

    else if jenkins_build.phase is JENKINS_BUILD_PHASE.COMPLETED and jenkins_build.status is JENKINS_BUILD_STATUS.SUCCESS
      if slack_room
        robot.messageRoom(slack_room, "<#{full_url}|#{root_job_name}/#{git_branch}>: Completed Successfully :confetti_ball:")
      jenkins_root_job_completed_successfully(robot, jenkins_job.name, jenkins_build)

    res.end "ok"
