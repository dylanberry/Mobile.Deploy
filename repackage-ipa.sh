#!/bin/bash
set -e # exit on first error.
packagePath=${1}
envName=${2}
certPath=${3}
certName=${4}
certPassword=$5
provisioningProfilePath=${6}
teamId=${7}
appName=${8}
displayName=${9}
bundleId=${10}
appStoreRelease=${11:-false}

echo " (i) packagePath: $packagePath"
echo " (i) envName: $envName"
echo " (i) certPath: $certPath"
echo " (i) certName: $certName"
echo " (i) certPassword: $certPassword"
echo " (i) provisioningProfilePath: $provisioningProfilePath"
echo " (i) teamId: $teamId"
echo " (i) appName: $appName"
echo " (i) displayName: $displayName"
echo " (i) bundleId: $bundleId"
echo " (i) appStoreRelease: $appStoreRelease"

#for local testing
#SYSTEM_DEFAULTWORKINGDIRECTORY="~/Documents"

echo " (i) Default directory: $SYSTEM_DEFAULTWORKINGDIRECTORY"
echo " (i) PWD: $PWD"

tempKeyChainFile="_xamariniostasktmp.keychain"
tempKeyChainPath="$SYSTEM_DEFAULTWORKINGDIRECTORY/packaging/$tempKeyChainFile"
tempKeyChainPassword="_xamariniostask_TmpKeychain_Pwd#1"

# Teardown trap runs regardless of exit code
function teardown {
    echo "Cleaning up."
    echo "note: this runs whether the script fails or not."
    /usr/bin/security delete-keychain $tempKeyChainPath || true
    rm -rf $SCRATCH || true
    cd $SYSTEM_DEFAULTWORKINGDIRECTORY || true
}
trap teardown EXIT

function setupTemporaryKeychain {
    echo " (i) create-keychain $tempKeyChainPath"
    /usr/bin/security create-keychain -p $tempKeyChainPassword $tempKeyChainPath
    echo " (i) set-keychain-settings $tempKeyChainPath"
    /usr/bin/security set-keychain-settings -lut 7200 $tempKeyChainPath
    /usr/bin/security unlock-keychain -p $tempKeyChainPassword $tempKeyChainPath
    /usr/bin/security import "$certPath" -P $certPassword -A -t cert -f pkcs12 -k $tempKeyChainPath
    /usr/bin/security list-keychain -d user
    /usr/bin/security list-keychain -d user -s $tempKeyChainPath ~/Library/Keychains/login.keychain-db
    /usr/bin/security list-keychain -d user
    /usr/bin/security find-identity -v -p codesigning $tempKeyChainPath
    /usr/bin/security cms -D -i $provisioningProfilePath
}

function initialize {
    echo " (i) Creating scratch directory"
    SCRATCH=$(mktemp -d)
    echo " (i) Scratch directory located at '$SCRATCH'"
}

function unzipPackage {
    echo " (i) Unziping the package for updating"
    unzip -q "$packagePath" -d $SCRATCH
}

function applyConfiguration {
    envConfig="app.$envName.config"
    echo " (i) envConfig: $envConfig"
    keepFile="$envConfig.keep"

    echo " (i) Rename $envConfig to $keepFile"
    mv "$SCRATCH/Payload/$appName.app/Assets/$envConfig" "$SCRATCH/Payload/$appName.app/Assets/$keepFile"

    echo " (i) Remove .config files"
    rm $SCRATCH/Payload/$appName.app/Assets/*.config

    echo " (i) Rename .keep to  app.config"
    mv "$SCRATCH/Payload/$appName.app/Assets/$keepFile" "$SCRATCH/Payload/$appName.app/Assets/app.config"
}

function updateDisplayName {
    echo " (i) Update App Bundle ID to ${bundleId}"
    plutil -replace CFBundleIdentifier -string $bundleId $SCRATCH/Payload/$appName.app/Info.plist

    echo " (i) Update App Name to ${displayName}"
    plutil -replace CFBundleDisplayName -string $envName $SCRATCH/Payload/$appName.app/Info.plist

    find $SCRATCH/Payload/$appName.app/ -name '*.strings'| while read filename; do
    echo " (i) Matching File: $filename"
    plutil -replace CFBundleDisplayName -string $displayName $filename
    done
}

function preparePackage {
    cd $SCRATCH

    echo " (i) Replacing the provisioning profile in Payload/$appName.app/embedded.mobileprovision with $provisioningProfilePath" 
    cp -f $provisioningProfilePath $SCRATCH/Payload/$appName.app/embedded.mobileprovision

    echo " (i) Extract existing entitlements"
    /usr/bin/codesign -d --verbose --entitlements :entitlements.plist "$SCRATCH/Payload/$appName.app"

    echo " (i) Original entitlements.plist"
    plutil -p entitlements.plist

    applicationIdentifier="$teamId.$bundleId"
    echo " (i) Update application-identifier in entitlements.plist to ${applicationIdentifier}"
    plutil -replace application-identifier -string $applicationIdentifier entitlements.plist


    if [ "$appStoreRelease" != "true" ] ; then
        echo " (i) Remove beta-reports-active from entitlements.plist"
        plutil -remove beta-reports-active entitlements.plist
    fi

    echo " (i) Updated entitlements.plist"
    plutil -p entitlements.plist

    echo " (i) Remove the _CodeSignature and CodeResources folders from the package"
    rm -rf "$SCRATCH/Payload/*.app/_CodeSignature" "$SCRATCH/Payload/*.app/CodeResources"
}

function signVerifyZip {
    echo " (i) Re-Signing application"
    /usr/bin/codesign -f -s $certName --entitlements entitlements.plist $SCRATCH/Payload/$appName.app --verbose

    echo " (i) Verifying app"
    /usr/bin/codesign -vv $SCRATCH/Payload/$appName.app

    echo " (i) Packaging the new application TO $SCRATCH/Payload/$appName.ipa"
    zip -qry $appName.ipa Payload
}

echo " (i) Move .ipa back to $packagePath"
mv $SCRATCH/$appName.ipa $packagePath