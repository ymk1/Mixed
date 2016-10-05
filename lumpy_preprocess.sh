#!/bin/bash -e

############################################################
#  Program: lumpyexpress
#  Author: Colby Chiang (cc2qe@virginia.edu)
############################################################
set -eo pipefail

# source the paths to the binaries used in the script
source_binaries() {
    if [[ -e $1 ]]
    then
	echo "Sourcing executables from $1 ..."
	if [[ $1 == /* ]]
	then
	    source $1
	else
	    source ./$1
	fi
    else
	echo "Config file $1 not found. Attempting to auto-source executables"
    # general
    LUMPY_HOME=$(dirname $(readlink -f $(which lumpyexpress)))
    if [ ! -d $LUMPY_HOME/scripts ]; then
        LUMPY_HOME=$LUMPY_HOME/..
    fi
    echo $LUMPY_HOME

	LUMPY=`which lumpy || true`
	SAMBLASTER=`which samblaster || true`
	SAMBAMBA=`which sambamba || true`
	SAMTOOLS=`which samtools || true`
	# python 2.7 or newer, must have pysam, numpy installed
	PYTHON=`which python || true`

        # python scripts
	PAIREND_DISTRO=$LUMPY_HOME/scripts/pairend_distro.py
	BAMGROUPREADS=$LUMPY_HOME/scripts/bamkit/bamgroupreads.py
	BAMFILTERRG=$LUMPY_HOME/scripts/bamkit/bamfilterrg.py
	BAMLIBS=$LUMPY_HOME/scripts/bamkit/bamlibs.py
    fi
}

# ensure that the require python modules are installed before
# beginning analysis
check_python_modules() {
    PYTHON_TEST=$1
    echo -e "\nChecking for required python modules ($PYTHON_TEST)..."

    $PYTHON_TEST -c "import imp; imp.find_module('pysam')"
    $PYTHON_TEST -c "import imp; imp.find_module('numpy')"
}

## usage
usage() {
    echo "
usage:   lumpy_preprocess [options]

options:
     -B FILE  full BAM file(s) (comma separated) (required)
     -h       show this message
"
}

# set defaults
LUMPY_DIR=`dirname $0`
CONFIG="$LUMPY_DIR/lumpyexpress.config"
THREADS=1
ANNOTATE=0
MIN_SAMPLE_WEIGHT=4
TRIM_THRES=0
EXCLUDE_BED=
TEMP_DIR=""
GENOTYPE=0
READDEPTH=0
VERBOSE=0
KEEP=0
OUTPUT=""
MAX_SPLIT_COUNT=2
MIN_NON_OVERLAP=20
PROB_CURVE=""
SPL_BAM_STRING=""
DISC_BAM_STRING=""
DEPTH_BED_STRING=""
VERBOSE=1

while getopts ":hB:" OPTION
do
    case "${OPTION}" in
	h)
	    usage
	    exit 0
	    ;;
	B)
	    FULL_BAM_STRING="$OPTARG"
	    ;;
    esac
done

# parse the BAM strings
FULL_BAM_LIST=($(echo $FULL_BAM_STRING | tr "," " "))
SPL_BAM_LIST=($(echo $SPL_BAM_STRING | tr "," " "))
DISC_BAM_LIST=($(echo $DISC_BAM_STRING | tr "," " "))
DEPTH_BED_LIST=($(echo $DEPTH_BED_STRING | tr "," " "))

OPTIND=0

# Check the for the relevant binaries
source_binaries $CONFIG

if [[ -z "$LUMPY" ]]
then
    usage
    echo -e "Error: lumpy executable not found. Please set path in $LUMPY_DIR/lumpyexpress.config file\n"
    exit 1
elif [[ -z  "$PAIREND_DISTRO" ]]
then
    usage
    echo -e "Error: pairend_distro.py executable not found. Please set path in $LUMPY_DIR/lumpyexpress.config file\n"
    exit 1
elif [[ -z "$BAMFILTERRG" ]]
then
    usage
    echo -e "Error: bamfilterrg.py executable not found. Please set path in $LUMPY_DIR/lumpyexpress.config file\n"
    exit 1
fi

# $SAMT will be either sambamba or samtools, depending on which is available
if [[ ! -z "$SAMBAMBA" ]]
then
    SAMT="$SAMBAMBA"
    SAMT_STREAM="$SAMBAMBA view -f bam -l 0"
    SAMTOBAM="$SAMBAMBA view -S -f bam -l 0"
    SAMSORT="$SAMBAMBA sort -m 1G --tmpdir "
elif [[ ! -z "$SAMTOOLS" ]]
then
    SAMT="$SAMTOOLS"
    SAMT_STREAM="$SAMTOOLS view -u"
    SAMTOBAM="$SAMTOOLS view -S -u"
    SAMSORT="$SAMTOOLS sort -m 1G -T "
else
    usage
    echo -e "Error: neither samtools nor sambamba were found. Please set path of one of these in $LUMPY_DIR/lumpyexpress.config file\n"
    exit 1
fi

# check for required python modules (pysam, numpy)
check_python_modules $PYTHON

# Check that the required files exist
if [[ ${#FULL_BAM_LIST[@]} -eq 0 ]]
then
    usage
    echo -e "Error: -B is required\n"
    exit 1
fi

set +o nounset
for TEST_BAM in ${FULL_BAM_LIST[@]} ${SPL_BAM_LIST[@]} ${DISC_BAM_LIST[@]}
do
    if [[ ! -f $TEST_BAM ]]
    then
	usage
	echo -e "Error: file $TEST_BAM not found.\n"
	exit 1
    fi
done

for TEST_BED in ${DEPTH_BED_LIST[@]}
do
	if [[ -z $(echo "$TEST_BED" | grep ":") ]]
	then
		usage
		echo -e "Error: must specify depths as sample_id:bedpe"
		exit 1;
	fi
	bpath=$(echo "$TEST_BED" | perl -pe 's/^.+://')
	if [[ ! -f "$bpath" ]]; then
		usage
		echo -e "Error: depth bed does not exist: $bpath"
		exit 1
	fi
done
set -o nounset

# default OUTPUT if not provided
if test -z "$OUTPUT"
then
    OUTPUT=`basename "${FULL_BAM_LIST[0]}"`.vcf
fi
OUTBASE=`basename "$OUTPUT"`

# make temporary directory
if [[ $VERBOSE -eq 1 ]]
then
    echo "
    create temporary directory"
fi
if [[ -z $TEMP_DIR ]]
then
    TEMP_DIR=`mktemp -d ${OUTBASE}.XXXXXXXXXXXX`
else
    mkdir -p $TEMP_DIR
fi


cleanup () {
	rm -rf $TEMP_DIR
}
trap cleanup EXIT

# If splitter and discordant BAMs not provided, generate them
# (LUMPY express)
set +o nounset
if [[ -z "${SPL_BAM_LIST}${DISC_BAM_LIST}" ]]
then
    # initialize split and discordant bam lists
    SPL_BAM_LIST=()
    DISC_BAM_LIST=()

    # create temp files and pipes
    mkdir -p $TEMP_DIR/spl $TEMP_DIR/disc
    # if [[ ! -e $TEMP_DIR/spl_pipe ]]
    # then
	# mkfifo $TEMP_DIR/spl_pipe
    # fi
    # if [[ ! -e $TEMP_DIR/disc_pipe ]]
    # then
	# mkfifo $TEMP_DIR/disc_pipe
    # fi

    # generate histo files and construct the strings for LUMPY
    for i in $( seq 0 $(( ${#FULL_BAM_LIST[@]}-1 )) )
    do
	FULL_BAM=${FULL_BAM_LIST[$i]}

	# calc readlength if not provided
	set +o pipefail
	READ_LENGTH=`$SAMT view $FULL_BAM | head -n 10000 | gawk 'BEGIN { MAX_LEN=0 } { LEN=length($10); if (LEN>MAX_LEN) MAX_LEN=LEN } END { print MAX_LEN }'`
	set -o pipefail

	# parse the libraries in the BAM header to extract readgroups from the same library
	LIB_RG_LIST=(`$PYTHON $BAMLIBS $FULL_BAM`)

	# process each library's splitters and discordants
	for j in $( seq 0 $(( ${#LIB_RG_LIST[@]}-1 )) )
	do
        SPLITTER=${FULL_BAM%.bam}.spl.sam
        DISCORDS=${FULL_BAM%.bam}.disc.sam

		if [[ "$VERBOSE" -eq 1 ]]; then
            echo -e "$PYTHON $BAMGROUPREADS --fix_flags -i $FULL_BAM -r ${LIB_RG_LIST[$j]} \
| $SAMBLASTER --acceptDupMarks --excludeDups --addMateTags --maxSplitCount $MAX_SPLIT_COUNT --minNonOverlap $MIN_NON_OVERLAP \
--splitterFile $SPLITTER --discordantFile $DISCORDS > /dev/null"
            echo -e "$SAMTOBAM $SPLITTER | $SAMSORT $TEMP_DIR/spl -o ${SPLITTER%.sam}.bam /dev/stdin"
            echo -e "$SAMTOBAM $DISCORDS | $SAMSORT $TEMP_DIR/disc -o ${DISCORDS%.sam}.bam /dev/stdin" 
        fi

	    $PYTHON $BAMGROUPREADS --fix_flags -i $FULL_BAM -r ${LIB_RG_LIST[$j]} \
		| $SAMBLASTER --acceptDupMarks --excludeDups --addMateTags --maxSplitCount $MAX_SPLIT_COUNT --minNonOverlap $MIN_NON_OVERLAP \
		    --splitterFile $SPLITTER --discordantFile $DISCORDS > /dev/null

        $SAMTOBAM $SPLITTER | $SAMSORT $TEMP_DIR/spl -o ${SPLITTER%.sam}.bam /dev/stdin && rm $SPLITTER
        $SAMTOBAM $DISCORDS | $SAMSORT $TEMP_DIR/disc -o ${DISCORDS%.sam}.bam /dev/stdin && rm $DISCORDS
	    wait

	    # generate discordant pair string for LUMPY
		# DISC_BAM=$TEMP_DIR/$OUTBASE.sample$(($i+1)).discordants.bam
		# DISC_SAMPLE=`$SAMT view -H $FULL_BAM | grep -m 1 "^@RG" | gawk -v i=$i '{ for (j=1;j<=NF;++j) {if ($j~"^SM:") { gsub("^SM:","",$j); print $j } } }'`
		# RG_STRING=`echo "${LIB_RG_LIST[$j]}" | sed 's/,/,read_group:/g' | sed 's/^/read_group:/g'`
		# MEAN=`cat ${TEMP_DIR}/$OUTBASE.sample$(($i+1)).lib$(($j+1)).insert.stats | tr '\t' '\n' | grep "^mean" | sed 's/mean\://g'`
		# STDEV=`cat ${TEMP_DIR}/$OUTBASE.sample$(($i+1)).lib$(($j+1)).insert.stats | tr '\t' '\n' | grep "^stdev" | sed 's/stdev\://g'`
		# LUMPY_DISC_STRING="$LUMPY_DISC_STRING -pe bam_file:${DISC_BAM},histo_file:${TEMP_DIR}/$OUTBASE.sample$(($i+1)).lib$(($j+1)).x4.histo,mean:${MEAN},stdev:${STDEV},read_length:${READ_LENGTH},min_non_overlap:${READ_LENGTH},discordant_z:5,back_distance:10,weight:1,id:${DISC_SAMPLE},min_mapping_threshold:20,${RG_STRING}"

	    # generate split-read string for LUMPY
		# SPL_BAM=$TEMP_DIR/$OUTBASE.sample$(($i+1)).splitters.bam
		# SPL_SAMPLE=`$SAMT view -H $FULL_BAM | grep -m 1 "^@RG" | gawk -v i=$i '{ for (j=1;j<=NF;++j) {if ($j~"^SM:") { gsub("^SM:","",$j); print $j } } }'`
		# LUMPY_SPL_STRING="$LUMPY_SPL_STRING -sr bam_file:${SPL_BAM},back_distance:10,min_mapping_threshold:20,weight:1,id:${SPL_SAMPLE},min_clip:20,${RG_STRING}"
	done

	# merge the splitters and discordants files
	# if [[ ${#LIB_RG_LIST[@]} -gt 1 ]]
	# then
		# MERGE_DISCORDANTS=""
		# MERGE_SPLITTERS=""
		# for j in $( seq 0 $(( ${#LIB_RG_LIST[@]}-1 )) )
		# do
		# MERGE_DISCORDANTS="$MERGE_DISCORDANTS $TEMP_DIR/$OUTBASE.sample$(($i+1)).lib$(($j+1)).discordants.bam"
		# MERGE_SPLITTERS="$MERGE_SPLITTERS ${TEMP_DIR}/$OUTBASE.sample$(($i+1)).lib$(($j+1)).splitters.bam"
		# done

		# if [[ $VERBOSE -eq 1 ]]
		# then
		# echo "
		# $SAMT merge ${TEMP_DIR}/$OUTBASE.sample$(($i+1)).discordants.bam $MERGE_DISCORDANTS
		# $SAMT merge ${TEMP_DIR}/$OUTBASE.sample$(($i+1)).splitters.bam $MERGE_SPLITTERS
		# rm $MERGE_DISCORDANTS $MERGE_SPLITTERS"
		# fi
		# $SAMT merge ${TEMP_DIR}/$OUTBASE.sample$(($i+1)).discordants.bam $MERGE_DISCORDANTS
		# $SAMT merge ${TEMP_DIR}/$OUTBASE.sample$(($i+1)).splitters.bam $MERGE_SPLITTERS
		# rm $MERGE_DISCORDANTS $MERGE_SPLITTERS
	# else
		# mv ${TEMP_DIR}/$OUTBASE.sample$(($i+1)).lib$(($j+1)).discordants.bam ${TEMP_DIR}/$OUTBASE.sample$(($i+1)).discordants.bam
		# mv ${TEMP_DIR}/$OUTBASE.sample$(($i+1)).lib$(($j+1)).splitters.bam ${TEMP_DIR}/$OUTBASE.sample$(($i+1)).splitters.bam
	# fi

	# update the splitters and discordant BAM lists
	# SPL_BAM_LIST+=(${TEMP_DIR}/$OUTBASE.sample$(($i+1)).splitters.bam)
	# DISC_BAM_LIST+=(${TEMP_DIR}/$OUTBASE.sample$(($i+1)).discordants.bam)
    done
exit
# else (user provided a splitter and discordants file)
else
    # parse the libraries in the BAM header to extract readgroups from the same library
    for i in $( seq 0 $(( ${#FULL_BAM_LIST[@]}-1 )) )
    do
	FULL_BAM=${FULL_BAM_LIST[$i]}
	DISC_BAM=${DISC_BAM_LIST[$i]}
	SPL_BAM=${SPL_BAM_LIST[$i]}

	# LIB_RG_LIST contains an element for each library in the BAM file.
	# These elements are comma delimited strings for the readgroups for each library.
	LIB_RG_LIST=(`$PYTHON $BAMLIBS ${FULL_BAM_LIST[$i]}`)


	if [[ ${#LIB_RG_LIST[@]} -eq 0 ]]
	then
	    echo "Warning: BAM file lacks read groups, paired-end analysis may fail"
	fi

	# generate the histo, stats, and config files
	echo "Calculating insert distributions... "
	for j in $( seq 0 $(( ${#LIB_RG_LIST[@]}-1 )) )
	do
	    # calculate read length if not provided
	    set +o pipefail
	    LIB_READ_LENGTH_LIST+=(`$SAMT view ${FULL_BAM_LIST[$i]} | head -n 10000 | gawk 'BEGIN { MAX_LEN=0 } { LEN=length($10); if (LEN>MAX_LEN) MAX_LEN=LEN } END { print MAX_LEN }'`)
	    echo "Library read groups: ${LIB_RG_LIST[$j]}"
	    echo "Library read length: ${LIB_READ_LENGTH_LIST[$j]}"
	    $SAMT_STREAM ${FULL_BAM_LIST[$i]} \
		| $PYTHON $BAMFILTERRG -n 10000000 --readgroup ${LIB_RG_LIST[$j]} \
		| grep -v '^@' \
		| tail -n 1000000 \
		| $PYTHON $PAIREND_DISTRO -r ${LIB_READ_LENGTH_LIST[$j]} -X 4 -N 1000000 -o ${TEMP_DIR}/$OUTBASE.sample$(($i+1)).lib$(($j+1)).x4.histo \
		> ${TEMP_DIR}/$OUTBASE.sample$(($i+1)).lib$(($j+1)).insert.stats
	    set -o pipefail
	done
	echo "done"

	# construct LUMPY_SPL_STRING
	SPL_SAMPLE=`$SAMT view -H $SPL_BAM | grep -m 1 "^@RG" | gawk -v i=$i '{ for (j=1;j<=NF;++j) {if ($j~"^SM:") { gsub("^SM:","",$j); print $j } } }'`
	LUMPY_SPL_STRING="$LUMPY_SPL_STRING -sr bam_file:${SPL_BAM},back_distance:10,min_mapping_threshold:20,weight:1,id:${SPL_SAMPLE},min_clip:20"

	# construct LUMPY_DISC_STRING
	for j in $( seq 0 $(( ${#LIB_RG_LIST[@]}-1 )) )
	do
	    echo $(( ${#FULL_BAM_LIST[@]}-1 ))
	    DISC_BAM=${DISC_BAM_LIST[$i]}
	    DISC_SAMPLE=`$SAMT view -H $DISC_BAM | grep -m 1 "^@RG" | gawk -v i=$i '{ for (j=1;j<=NF;++j) {if ($j~"^SM:") { gsub("^SM:","",$j); print $j } } }'`
	    MEAN=`cat ${TEMP_DIR}/$OUTBASE.sample$(($i+1)).lib$(($j+1)).insert.stats | tr '\t' '\n' | grep "^mean" | sed 's/mean\://g'`
	    STDEV=`cat ${TEMP_DIR}/$OUTBASE.sample$(($i+1)).lib$(($j+1)).insert.stats | tr '\t' '\n' | grep "^stdev" | sed 's/stdev\://g'`
	    RG_STRING=`echo "${LIB_RG_LIST[$j]}" | sed 's/,/,read_group:/g' | sed 's/^/read_group:/g'`

	    if [[ "$MEAN" != "NA" ]] && [[ "$STDEV" != "NA" ]]
	    then
		LUMPY_DISC_STRING="$LUMPY_DISC_STRING -pe bam_file:${DISC_BAM},histo_file:${TEMP_DIR}/$OUTBASE.sample$(($i+1)).lib$(($j+1)).x4.histo,mean:${MEAN},stdev:${STDEV},read_length:${LIB_READ_LENGTH_LIST[$j]},min_non_overlap:${LIB_READ_LENGTH_LIST[$j]},discordant_z:5,back_distance:10,weight:1,id:${DISC_SAMPLE},min_mapping_threshold:20,${RG_STRING}"
	    fi
	done
    done
fi

LUMPY_DEPTH_STRING=""
if [[ ! -z "$DEPTH_BED_LIST" ]]; then
	# -bedpe bedpe_file:<bedpe file>,id:<sample name>,weight:<sample weight>
	set -o nounset
	for j in $( seq 0 $(( ${#DEPTH_BED_LIST[@]}-1 )) )
	do
		rec=${DEPTH_BED_LIST[$j]}
		f=$(echo $rec | perl -pe 's/^.+://')
		sample=$(echo $rec | perl -pe 's/:.+$//')
		# give weight of 4 since these have been called before.
		LUMPY_DEPTH_STRING="$LUMPY_DEPTH_STRING -bedpe bedpe_file:$f,id:$sample,weight:4"
	done
	set +o nounset

fi

echo "Running LUMPY... "
if [[ "$VERBOSE" -eq 1 ]]
then
    echo "
$LUMPY ${PROB_CURVE} \\
    -t ${TEMP_DIR}/${OUTBASE} \\
    -msw $MIN_SAMPLE_WEIGHT \\
    -tt $TRIM_THRES \\
    $LUMPY_DEPTH_STRING \\
    $EXCLUDE_BED_FMT \\
    $LUMPY_DISC_STRING \\
    $LUMPY_SPL_STRING \\
    > $OUTPUT"
fi
# call lumpy
$LUMPY -b $PROB_CURVE -t ${TEMP_DIR}/${OUTBASE} -msw $MIN_SAMPLE_WEIGHT -tt $TRIM_THRES \
    $LUMPY_DEPTH_STRING \
    $EXCLUDE_BED_FMT \
    $LUMPY_DISC_STRING \
    $EXCLUDE_BED_FMT \
    $LUMPY_SPL_STRING \
    > $OUTPUT

# clean up
if [[ "$KEEP" -eq 0 ]]
then
    rm -r ${TEMP_DIR}
fi

echo "LUMPY Express done"

# exit cleanly
exit 0


## END SCRIPT
