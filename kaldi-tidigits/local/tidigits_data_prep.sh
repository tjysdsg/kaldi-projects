#!/bin/bash
. ./path.sh # Needed for KALDI_ROOT

if [ $# -ne 1 ]; then
   echo "Argument should be the TIDIGITS directory, see ../run.sh for example."
   exit 1;
fi

tidigits=$1

# data/local/data
tmpdir=`pwd`/data/local/data
mkdir -p $tmpdir

# Note: the .wav files are not in .wav format but "sphere" format (this was 
# produced in the days before Windows).

rootdir=$tidigits

find $rootdir/train -name '*.WAV' > $tmpdir/train.flist
find $rootdir/test -name '*.WAV' > $tmpdir/test.flist

sph2pipe=${KALDI_ROOT}tools/sph2pipe_v2.5/sph2pipe
if [ ! -x $sph2pipe ]; then
    echo "Could not find (or execute) the sph2pipe program at $sph2pipe";
    exit 1;
fi

for x in train test; do
    # get scp file that has utterance-ids and maps to the sphere file.
    cat $tmpdir/$x.flist | perl -ane 'm|/([A-Z])[A-Z]*/(..)/([1-9ZO]+[AB])\.WAV| || die "bad line $_"; print "$1$2_$3 $_"; ' | sort > $tmpdir/${x}_sph.scp
    # turn it into one that has a valid .wav format in the modern sense (i.e. RIFF format, not sphere).
    # This file goes into its final location
    mkdir -p data/$x
    awk '{printf("%s '$sph2pipe' -f wav %s |\n", $1, $2);}' < $tmpdir/${x}_sph.scp > data/$x/wav.scp
    
    # Now get the "text" file that says what the transcription is
    cat data/$x/wav.scp | perl -ane 'm/^(..._([1-9ZO]+)[AB]) / || die; $text = join(" ", split("", $2)); print "$1 $text\n";' < data/$x/wav.scp > data/$x/text
    
    # now get the "utt2spk" file that says, for each utterance, the speaker name.  
    perl -ane 'm/^((...)_\S+) / || die; print "$1 $2\n"; ' < data/$x/wav.scp > data/$x/utt2spk
    # create the file that maps from speaker to utterance-list.
    utils/utt2spk_to_spk2utt.pl < data/$x/utt2spk > data/$x/spk2utt
done

GREEN='\033[0;32m'
NC='\033[0m' # No Color
echo -e "${GREEN}Data preparation succeeded${NC}"
