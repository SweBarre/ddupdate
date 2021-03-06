#!/bin/bash

## Function to print help
function printHelp {
  echo "Usage
  ${0##*/} -c <config file> [-v -h -d]

    -c <config file>	:	use config file
    -v			:	verbose output
    -d			:	print debug info
    -h 			:	print this help"
    
}

DEBUG=/bin/false
VERBOSE=/bin/false
CACHEFILE=/tmp/
ERROR=/bin/true

function output {
  TIMESTAMP=$(date +"%F %H:%M:%S")
  if [[ "$2" == "$ERROR" ]]; then
    echo  -e "[$TIMESTAMP]  $1" >&2
  else
    echo  -e "[$TIMESTAMP]  $1"
  fi
}


## Function to check if we resolved a good IP address
function testIPv4 {
  ip=$1
  if [[ "$ip" =~ ^([0-9]{1,3})[.]([0-9]{1,3})[.]([0-9]{1,3})[.]([0-9]{1,3})$ ]]; then
    for (( i=1; i<${#BASH_REMATCH[@]}; ++i ))
    do
      (( ${BASH_REMATCH[$i]} <= 255 )) || { output "Resolved in a bad IP address, value=$ip" $ERROR; exit 1; }
    done
  else
      output "Resolved in a bad IP address, value=$ip" $ERROR
      exit 1
  fi
}


#Read the command line arguments

while getopts ":c:vhd" opt; do
  case $opt in
    c)
        CONFIGFILE="$OPTARG"
        ;;
    v)
        VERBOSE=/bin/true
        ;;
    d)
        DEBUG=/bin/true
        ;;
    h)
        printHelp
        ;;
    \?)
        echo "Invalid option: -$OPTARG" >&2
        printHelp
        exit 1
        ;;
    :)
        output "option -$OPTARG requires an argument" $ERROR
        printHelp
        exit 1
      ;;
  esac
done

# Check to see if prerequisites are present
$DEBUG && output "Checking prerequisites.."
type curl >/dev/null 2>&1 || { output "curl not found, quitting!" $ERROR; exit 1; }
type sed >/dev/null 2>&1 || { output "sed not found, quitting!" $ERROR; exit 1; }


#Check to see if config file is there and source it
$DEBUG && output "reading config file '$CONFIGFILE'"
[[ -z "$CONFIGFILE" ]] && { output "No configuration file specified" $ERROR; exit 1; }
if [[ ! -f "$CONFIGFILE" ]]; then
  output "the '$CONFIGFILE' is not a file" $ERROR;
  exit 1
fi
if [[ ! -r "$CONFIGFILE" ]]; then
  output "the '$CONFIGFILE' is not a readeble" $ERROR;
  exit 1
fi
. "$CONFIGFILE"

# Check if DEBUG and if curl output should be silent or not
SILENT_CURL="-s"
$DEBUG && SILENT_CURL=""

#Check to see if we have all the variables we need.
$DEBUG && output "Checking mandatory variables...."
[[ -z "$CHECK_IP_URL" ]] && { output "CHECK_IP_URL not set" $ERROR; exit 1; }
[[ -z "$UPDATE_DNS_URL" ]] && { ouput "UPDATE_DNS_URL not set" $ERROR; exit 1; }
[[ -z "$USERNAME" ]] && { output "USERNAME not set" $ERROR; exit 1; }
[[ -z "$PASSWORD" ]] && { output "PASSWORD not set" $ERROR; exit 1; }
[[ -z "$HOSTS" ]] && { output "HOSTS not set" $ERROR; exit 1; }
[[ -z "$CACHEDIR" ]] && { output "CACHEDIR not set" $ERROR; exit 1; }

# Checking cache file
CACHEFILE="$CACHEDIR/${CONFIGFILE##*/}.cache"
if [[ ! -f "$CACHEFILE" ]]; then
  $DEBUG && output "Creating cache file $CACHEFILE .."
  touch "$CACHEFILE" || { output "Could not create $CACHEFILE" $ERROR; exit 1; }
elif [[ ! -w "$CACHEFILE" ]]; then
  output "cache fil $CACHEFILE is not writable" $ERROR
  exit 1
else
  $DEBUG && output "Using existin Cache file: $CACHEFILE ..."
fi

# Fetching IP Address
$DEBUG && output "Fetching IP using URL=$CHECK_IP_URL"
# fetching the IP and filter out unwanted HTML-tags
IPADDRESS=$(curl $SILENT_CURL $CHECK_IP_URL | sed -e 's/<title>.*<\/title>//I' -e 's/<[^>]\+>//g')
if [[ ! -z $IPFILTER ]]; then
  IPADDRESS=$(echo $IPADDRESS | sed "$IPFILTER")
fi
$DEBUG && output "got IP=$IPADDRESS"
testIPv4 $IPADDRESS

#Start the updating loop
for HOST in ${HOSTS[@]}; do
  # Get the values from cache file
  $DEBUG && output "Checking host=$HOST"
  IP_CACHE=$(grep "host=$HOST" $CACHEFILE | sed 's/.*ip=\([0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\).*/\1/')
  $DEBUG && output "Cached IP=$IP_CACHE"
  if [[ "$IPADDRESS" == "$IP_CACHE" ]]; then
    ($DEBUG || $VERBOSE) && output "$HOST IP Address hasn't changed : $IPADDRESS"
  else
    # create the URL
    UPDATE_DNS_URL_HOST=$(sed -e "s/{A-RECORD}/$HOST/g" -e "s/{IP}/$IPADDRESS/g" <<< $UPDATE_DNS_URL)
    $DEBUG && output "Update $HOST\t-> $IPADDRESS\t URL=$UPDATE_DNS_URL_HOST"
    $VERBOSE && output "Update $HOST\t-> $IPADDRESS\t"
    RESPONSE=$(curl $SILENT_CURL --user "$USERNAME:$PASSWORD" "$UPDATE_DNS_URL_HOST")
    if [[ "$RESPONSE" == "good" || "$RESPONSE" == "nochg" ]]; then
      ## updating cache
      $DEBUG && output "updating cache file"
      CACHE_COUNT=$(grep --count "host=$HOST" $CACHEFILE)
      if [[ $CACHE_COUNT == 0 ]]; then
        $DEBUG && output "creating new cache entry for $HOST, ip=$IPADDRESS"
        echo "host=$HOST,ip=$IPADDRESS" >> $CACHEFILE || output "error updating cache file" $ERROR
      else
        sed -i "s/^.*host=${HOST}.*$/host=${HOST},ip=$IPADDRESS/g" $CACHEFILE || output "error updating cache file" $ERROR
      fi
      if [[ $CACHE_COUNT > 1 ]];then
        output "Duplicate cache entries found for $HOST" $ERROR
      fi
    fi
    if [[ "$RESPONSE" == "nochg" ]]; then
      output "Got nochg while updating $HOST -> $IPADDRESS  If this continues you may be blocked" $ERROR
    else
      output "Got error while updating $HOST -> $IPADDRESS : $RESPONSE" $ERROR
    fi
  fi
done

$DEBUG && output "Finished run.."
exit 0
