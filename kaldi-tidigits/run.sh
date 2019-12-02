#!/bin/bash
. ./cmd.sh ## You'll want to change cmd.sh to something that will work on your system. This relates to the queue.
rm results.txt
rm -rf data exp mfcc

tidigits=/home/tjy/tidigits

# The following command prepares the data/{train,dev,test} directories.
local/tidigits_data_prep.sh $tidigits || exit 1;
local/tidigits_prepare_lang.sh  || exit 1;
utils/validate_lang.pl data/lang || exit 1;

# make MFCC features.
mfccdir=mfcc
for x in test train; do
    steps/make_mfcc.sh --cmd "$train_cmd" --nj 20 data/$x exp/make_mfcc/$x $mfccdir || exit 1;
    steps/compute_cmvn_stats.sh data/$x exp/make_mfcc/$x $mfccdir || exit 1;
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

GREEN='\033[0;32m'
NC='\033[0m' # No Color
echo -e "${GREEN}See results.txt for test result${NC}"
