var gcloud = require('gcloud');
var sprintf = require('sprintf-js').sprintf;

// These values can be obtained from the JSON key file you download when creating
// a service account.
// Required GCE configs
var GCE_PROJECT_ID = process.env.GCE_PROJECT_ID;
var GCE_CREDENTIALS_CLIENT_EMAIL = process.env.GCE_CREDENTIALS_CLIENT_EMAIL;
var GCE_CREDENTIALS_PRIVATE_KEY = process.env.GCE_CREDENTIALS_PRIVATE_KEY;
var GCE_DISK_SOURCE_IMAGE = process.env.GCE_DISK_SOURCE_IMAGE;
// Optional GCE configs
var GCE_MACHINE_TYPE = process.env.GCE_MACHINE_TYPE || 'n1-highcpu-2';
var GCE_MACHINE_COUNT = parseInt(process.env.GCE_MACHINE_COUNT, 10) || 1;
var GCE_REGION = process.env.GCE_REGION || 'us-central1';

var DISK_TYPE_TPL = "zones/%s/diskTypes/pd-ssd";

var gce = gcloud.compute({
  projectId: GCE_PROJECT_ID,
  credentials: {
      client_email: GCE_CREDENTIALS_CLIENT_EMAIL,
      private_key: GCE_CREDENTIALS_PRIVATE_KEY
  }
});

var vmConfig = {
    machineType: GCE_MACHINE_TYPE,
    disks: [
        {
            boot: true,
            "initializeParams": {
                "sourceImage": sprintf("global/images/%s", GCE_DISK_SOURCE_IMAGE),
                "diskType": "zones/us-central1-a/diskTypes/pd-ssd"
            },
            "autoDelete": true
        }
    ],
    networkInterfaces: [
        {
            network: "global/networks/default",
            accessConfigs: [
                {
                    type: "ONE_TO_ONE_NAT",
                    name: "External NAT"
                }
            ]
        }
    ],
    "scheduling": {
        "onHostMaintenance": "TERMINATE",
        "automaticRestart": false,
        "preemptible": true
    }
};

function creationCallback(err, vm, operation, apiResponse) {
    if (err) {
        console.log(err);
        return;
    }

    console.log("VM creation call succeeded for: %s", vm.name);
    operation.onComplete(function(err, metadata) {
        if (err) {
            console.log(err);
            return;
        }
        console.log("VM created: %s", metadata.name);
    });
}

var timestamp = Math.floor(new Date() / 1000);
var launchZoneLetters = [
    'a'
];
var numZones = launchZoneLetters.length;
for (var j = 0; j < numZones; j++) {
    // TODO: Split desired number of machines across the zones
    // with a strategy that's aware of zones that are "busy" and have terminated preemptable machines. If there are no VMs currently up, split the machines evenly across all zones. If there are VMs currently up, though, only place instances in zones that already have instances (since those aren't busy). This strategy is naive (it doesn't do anything to test if a zone is no longer busy), but if zone business is pretty consistent within a day, it's a simple way to get close to optimal distribution.
    // zone1.getVMs(function(err, vms) {console.log(vms)});

    var zoneLetter = launchZoneLetters[j];
    var zoneName = sprintf('%s-%s', GCE_REGION, zoneLetter);
    var desiredMachineCount = GCE_MACHINE_COUNT;
    console.log("Launching %s machines in zone %s", desiredMachineCount, zoneName);

    // The diskType config must be zone-specific
    vmConfig.disks[0].initializeParams.diskType = sprintf(DISK_TYPE_TPL, zoneName);

    var zone = gce.zone(zoneName);
    for (var i = 0; i < desiredMachineCount; i++) {
        var vmName = sprintf(
            'worker-%s-zone-%s-%02d',
            timestamp,
            zoneLetter,
            i
        )
        console.log("Creating VM: %s", vmName);
        zone.createVM(
            vmName,
            vmConfig,
            creationCallback
        );
    }
}
