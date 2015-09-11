var gcloud = require('gcloud');
var sprintf = require('sprintf-js').sprintf;
var util = require('util');

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
var GCE_COMPUTE_ENGINE_SERVICE_ACCOUNT_EMAIL = process.env.GCE_COMPUTE_ENGINE_SERVICE_ACCOUNT_EMAIL || '';

var DISK_TYPE_TPL = "zones/%s/diskTypes/pd-ssd";
var GCE_ZONE_LETTERS = [
    'a',
    'b',
    'c',
    'f'
];

var gce = gcloud.compute({
  projectId: GCE_PROJECT_ID,
  credentials: {
      client_email: GCE_CREDENTIALS_CLIENT_EMAIL,
      private_key: GCE_CREDENTIALS_PRIVATE_KEY
  }
});
var allVms = [];
var zoneResultsCount = 0;

for (var i = 0; i < GCE_ZONE_LETTERS.length; i++) {
    var zoneLetter = GCE_ZONE_LETTERS[i];
    var zoneName = sprintf('%s-%s', GCE_REGION, zoneLetter);
    var zone = gce.zone(zoneName);

    // Determine which zones are busy, based on which currently have VMs,
    // so that we can spread our workers across zones.
    // This minimizes the likelihood of all of our workers being prempted at the same time.
    zone.getVMs(aggregateVMsAcrossZones);
}

function aggregateVMsAcrossZones(err, vms) {
    if (err) {
        console.log("Error retrieving current VM list");
        console.log(err);
        return;
    }

    zoneResultsCount += 1;
    allVms = allVms.concat(vms);

    if (zoneResultsCount == GCE_ZONE_LETTERS.length) {
        console.log("VM list retrieved for all %s zones", zoneResultsCount);
        // We have results from all zones
        distributeVMsAcrossNonBusyZones(allVms);
    }else {
        console.log("VM list pending for %s more zone(s)", GCE_ZONE_LETTERS.length - zoneResultsCount);
    }
}

function distributeVMsAcrossNonBusyZones(vms) {
    console.log("Determining desired worker distribution across zones");
    console.log("%s existing workers located", vms.length);
    var vmCountByZone = {};

    for (var i = 0; i < vms.length; i++) {
        // Only STAGING and RUNNING statuses indicate that there are available resources in a zone
        // see: https://cloud.google.com/compute/docs/instances/#checkmachinestatus
        var vm = vms[i];
        var status = vm.metadata.status;
        if (status === 'STAGING' || status === 'RUNNING') {
            var zone = vm.zone.name;
            if (!(zone in vmCountByZone)) {
                console.log("VM located in %s", zone);
                vmCountByZone[zone] = 1;
            } else {
                vmCountByZone[zone] += 1;
            }
        } else {
            console.log("Ignoring VM %s with status: %s", vm.name, status);
        }
    }

    zoneLettersNotBusy = getZoneLettersNotBusy(vmCountByZone);
    console.log("Zones not busy: ", zoneLettersNotBusy);
    workerNumbersByZoneLetter = distributeWorkersAcrossZones(zoneLettersNotBusy, GCE_MACHINE_COUNT);

    var timestamp = Math.floor(new Date() / 1000);
    for (var zoneLetter in workerNumbersByZoneLetter) {
        if (workerNumbersByZoneLetter.hasOwnProperty(zoneLetter)) {
            createWorkersInZone(
                workerNumbersByZoneLetter[zoneLetter],
                zoneLetter,
                timestamp
            );
        }
    }

    function getZoneLettersNotBusy(vmCountByZone) {
        var vmCountByZoneLetter = {};
        for (var zoneUrl in vmCountByZone) {
            if (vmCountByZone.hasOwnProperty(zoneUrl)) {
                var zoneLetter = zoneUrl.charAt(zoneUrl.length-1);
                if (!(zoneLetter in vmCountByZoneLetter)) {
                    vmCountByZoneLetter[zoneLetter] = 1;
                } else {
                    vmCountByZoneLetter[zoneLetter] += 1;
                }
            }
        }

        var zoneLettersNotBusy = [];
        for (var zoneLetter in vmCountByZoneLetter) {
            if (vmCountByZoneLetter.hasOwnProperty(zoneLetter)) {
                zoneLettersNotBusy.push(zoneLetter);
            }
        }

        // If everything is busy, let's just spread across known zones
        if (zoneLettersNotBusy.length == 0) {
            console.log("No zones have existing workers. Distributing across: %s", GCE_ZONE_LETTERS);
            zoneLettersNotBusy = GCE_ZONE_LETTERS;
        }

        return zoneLettersNotBusy;
    }

    function distributeWorkersAcrossZones(zoneLetters, workerCount) {
        var maxWorkersPerZone = Math.ceil(workerCount / zoneLetters.length);
        console.log("Placing a max of %s workers in each zone", maxWorkersPerZone);
        var workerIndexes = []
        for (var i = 0; i < workerCount; i++) {
            workerIndexes.push(i);
        }

        // Distribute the indexes evenly across the zones.
        // The last zones will get 1 less if it doesn't work out evenly.
        // In the case of very low numbers (e.g. 5 nodes in 4 zones),
        // it's possible for zones to get no indexes.
        var workersByZoneLetter = {};
        var i = 0;
        for (var j = 0; j < zoneLetters.length; j++) {
            var zoneLetter = zoneLetters[j];
            workersByZoneLetter[zoneLetter] = workerIndexes.slice(i, i + maxWorkersPerZone);
            console.log("Zone %s will have workers: %s", zoneLetter, workersByZoneLetter[zoneLetter]);
            i += maxWorkersPerZone;
        }
        return workersByZoneLetter;
    }
}


function createWorkersInZone(workerIndexes, zoneLetter, timestamp) {
    var zoneName = sprintf('%s-%s', GCE_REGION, zoneLetter);
    var desiredMachineCount = workerIndexes.length;
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
    console.log("Launching %s machines in zone %s", desiredMachineCount, zoneName);

    // The diskType config must be zone-specific
    vmConfig.disks[0].initializeParams.diskType = sprintf(DISK_TYPE_TPL, zoneName);

    if (GCE_COMPUTE_ENGINE_SERVICE_ACCOUNT_EMAIL.length > 0) {
        // We have a service account, so let's give the machine read/write compute access
        vmConfig["serviceAccounts"] = [
            {
                "email": GCE_COMPUTE_ENGINE_SERVICE_ACCOUNT_EMAIL,
                "scopes": [
                    // We want the VMs to be able to shut themselves down
                    "https://www.googleapis.com/auth/compute"
                ]
            }
        ]
    }
    var zone = gce.zone(zoneName);
    for (var i = 0; i < desiredMachineCount; i++) {
        var vmName = sprintf(
            'worker-%s-zone-%s-%02d',
            timestamp,
            zoneLetter,
            workerIndexes[i]
        )
        console.log("Creating VM: %s", vmName);
        zone.createVM(
            vmName,
            vmConfig,
            creationCallback
        );
    }
}

function creationCallback(err, vm, operation, apiResponse) {
    if (err) {
        console.log("Error creating VM");
        console.log(err);
        return;
    }

    console.log("VM creation call succeeded for: %s", vm.name);
    operation.onComplete(
        {'maxAttempts': 4, 'interval': 3000},
        function(err, metadata) {
            if (err) {
                if (err.code === 'OPERATION_INCOMPLETE') {
                    console.log(
                        "Not waiting for VM %s to complete operation %s",
                        vm.name,
                        metadata.name,
                    );
                    return;
                }
                console.log(err);
                return;
            }
            console.log("VM created: %s", metadata.name);
        }
    );
}
