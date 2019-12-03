#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color
. ./cmd.sh ## You'll want to change cmd.sh to something that will work on your system. This relates to the queue.
rm results.txt
rm -rf data exp mfcc

feature_method=mfcc
if [ $# -ne 1 ]; then
    echo -e "${RED}using default mfcc${NC}"
else
    echo -e "${RED}using $1${NC}"
    feature_method=$1
fi

tidigits=/home/tjy/tidigits

# The following command prepares the data/{train,dev,test} directories.
local/tidigits_data_prep.sh $tidigits || exit 1;
local/tidigits_prepare_lang.sh  || exit 1;
utils/validate_lang.pl data/lang || exit 1;

# feature extraction
featdir=${feature_method}
for x in test train; do
    if [ ${feature_method} = "mfcc" ]; then
        steps/make_mfcc.sh --cmd "$train_cmd" --nj 20 data/$x exp/make_${feature_method}/$x $featdir || exit 1;
        steps/compute_cmvn_stats.sh data/$x exp/make_${feature_method}/$x $featdir || exit 1;
    elif [ ${feature_method} = "mfcc-pitch" ]; then
        steps/make_mfcc_pitch.sh --cmd "$train_cmd" --nj 20 data/$x exp/make_${feature_method}/$x $featdir || exit 1;
        steps/compute_cmvn_stats.sh data/$x exp/make_${feature_method}/$x $featdir || exit 1;
    elif [ ${feature_method} = "fbank-pitch" ]; then
        steps/make_fbank_pitch.sh --cmd "$train_cmd" --nj 20 data/$x exp/make_${feature_method}/$x $featdir || exit 1;
        steps/compute_cmvn_stats.sh data/$x exp/make_${feature_method}/$x $featdir || exit 1;
    elif [ ${feature_method} = "fbank" ]; then
        steps/make_fbank.sh --cmd "$train_cmd" --nj 20 data/$x exp/make_${feature_method}/$x $featdir || exit 1;
        steps/compute_cmvn_stats.sh data/$x exp/make_${feature_method}/$x $featdir || exit 1;
    elif [ ${feature_method} = "plp" ]; then
        steps/make_plp.sh --cmd "$train_cmd" --nj 20 data/$x exp/make_${feature_method}/$x $featdir || exit 1;
        steps/compute_cmvn_stats.sh data/$x exp/make_${feature_method}/$x $featdir || exit 1;
    elif [ ${feature_method} = "plp-pitch" ]; then
        steps/make_plp_pitch.sh --cmd "$train_cmd" --nj 20 data/$x exp/make_${feature_method}/$x $featdir || exit 1;
        steps/compute_cmvn_stats.sh data/$x exp/make_${feature_method}/$x $featdir || exit 1;
# echo "  --pitch-postprocess-config <postprocess-config-file> # config passed to process-kaldi-pitch-feats "
# echo "  --paste-length-tolerance   <tolerance>               # length tolerance passed to paste-feats"
    else
	echo -e "${RED}unknown feature extraction method '${feature_method}'${NC}"
    fi
done

# utils/subset_data_dir.sh data/train 1000 data/train_1k

# try --boost-silence 1.25 to some of the scripts below (also 1.5, if that helps...
# effect may not be clear till we test triphone system.

# steps/train_mono.sh  --nj 4 --cmd "$train_cmd" data/train_1k data/lang exp/mono0a
steps/train_mono.sh  --nj 4 --cmd "$train_cmd" data/train data/lang exp/mono0a

utils/mkgraph.sh data/lang exp/mono0a exp/mono0a/graph && steps/decode.sh --nj 10 --cmd "$decode_cmd" exp/mono0a/graph data/test exp/mono0a/decode

steps/align_si.sh --nj 4 --cmd "$train_cmd" data/train data/lang exp/mono0a exp/mono0a_ali

steps/train_deltas.sh --cmd "$train_cmd" 2000 10000 data/train data/lang exp/mono0a_ali exp/tri1

utils/mkgraph.sh data/lang exp/tri1 exp/tri1/graph
steps/decode.sh --nj 10 --cmd "$decode_cmd" exp/tri1/graph data/test exp/tri1/decode

# utils/int2sym.pl -f 2- data/lang/words.txt exp/tri1/decode/scoring/19.tra | sed "s/ $//" | sort | diff - data/test/text >> results.txt

# Getting results, check results.txt
for x in exp/*/decode*; do [ -d $x ] && grep SER $x/wer_* | utils/best_wer.sh >> results.txt; done

echo -e "${GREEN}See results.txt for test result${NC}"
