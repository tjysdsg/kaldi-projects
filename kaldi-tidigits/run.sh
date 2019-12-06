#!/bin/bash

# color escape sequence definition
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# cmd definition (run.pl or queue.pl)
. ./cmd.sh

# clean previous data
rm -rf data exp mfcc

# default value of arguments
feature_method=mfcc
num_leaves=1000
tot_gauss=10000

# argument parsing
while [ $1 ]; do
    if [ $1 = "--feature-method" ]; then
        shift 1
        feature_method=$1
        shift 1
    elif [ $1 = "--num-leaves" ]; then
        shift 1
	num_leaves=$1
	shift 1
    elif [ $1 = "--tot-gauss" ]; then
        shift 1
	tot_gauss=$1
	shift 1
    else
	echo -e "${RED}UNKOWN ARGUMENT KEY: $1${NC}"
	exit 1
    fi
done

# print parameters used
echo -e "${RED}"
echo -e "using parameter --feature-method: ${feature_method}"
echo -e "using parameter --num-leaves: ${num_leaves}"
echo -e "using parameter --tot-gauss: ${tot_gauss}"
echo -e "${NC}"

# data dir
tidigits=/home/tjy/tidigits

# prepare data and language model
local/tidigits_data_prep.sh $tidigits || exit 1;
local/tidigits_prepare_lang.sh  || exit 1;

# validate language model
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
    else
	echo -e "${RED}unknown feature extraction method '${feature_method}'${NC}"
    fi
done

# subset data
# utils/subset_data_dir.sh data/train 1000 data/train_1k

# try --boost-silence 1.25 to some of the scripts below (also 1.5, if that helps...
# effect may not be clear till we test triphone system.
steps/train_mono.sh  --nj 4 --cmd "$train_cmd" data/train data/lang exp/mono0a

utils/mkgraph.sh data/lang exp/mono0a exp/mono0a/graph && steps/decode.sh --nj 10 --cmd "$decode_cmd" exp/mono0a/graph data/test exp/mono0a/decode

steps/align_si.sh --nj 4 --cmd "$train_cmd" data/train data/lang exp/mono0a exp/mono0a_ali

steps/train_deltas.sh --cmd "$train_cmd" ${num_leaves} ${tot_gauss} data/train data/lang exp/mono0a_ali exp/tri1

utils/mkgraph.sh data/lang exp/tri1 exp/tri1/graph
steps/decode.sh --nj 10 --cmd "$decode_cmd" exp/tri1/graph data/test exp/tri1/decode

# view test results
# utils/int2sym.pl -f 2- data/lang/words.txt exp/tri1/decode/scoring/19.tra | sed "s/ $//" | sort | diff - data/test/text >> results.txt

# output results to a text file
for x in exp/*/decode*; do [ -d $x ] && grep SER $x/wer_* | utils/best_wer.sh >> results_${feature_method}-${num_leaves}-${tot_gauss}.txt; done

echo -e "${GREEN}See results_${feature_method}-${num_leaves}-${tot_gauss}.txt for test result${NC}"
