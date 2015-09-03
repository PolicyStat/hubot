var gcloud = require('gcloud');

// Authorizing on a per-API-basis. You don't need to do this if you auth on a
// global basis (see Authorization section above).

var gce = gcloud.compute({
  projectId: 'pstat-jenkins-slaves',
  keyFilename: '/home/wes/policystat/fabric/gce/gce_jenkins_slave_account.json'
});

// Create a new VM using the latest OS image of your choice.
var zone1 = gce.zone('us-central1-a');
var zone2 = gce.zone('us-central1-b');
var DESIRED_COUNT = 26;

// zone1.getVMs(function(err, vms) {console.log(vms)});

var vmConfig = {
    machineType: 'n1-highcpu-2',
    disks: [
        {
            boot: true,
            "initializeParams": {
                "sourceImage": "https://www.googleapis.com/compute/v1/projects/pstat-jenkins-slaves/global/images/jenkins-slave-1436458131",
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

    console.log("VM creation call succeeded for: " + vm.name);
    operation.onComplete(function(err, metadata) {
        if (err) {
            console.log(err);
            return;
        }
        console.log("VM created: " + metadata.name);
    });
}

var timestamp = Math.floor(new Date() / 1000);
for (var i = 0; i < DESIRED_COUNT; i++) {
    zone1.createVM('worker-' + timestamp + '-' + i, vmConfig, creationCallback);
}
