#!/bin/bash
mkdir -p /home/tjy/data/librispeech_data/export/a15/vpanayotov/data
data=/home/tjy/data/librispeech_data/export/a15/vpanayotov/data

# base url for downloads.
data_url=www.openslr.org/resources/12
lm_url=www.openslr.org/resources/11
mfccdir=mfcc
stage=21

. ./cmd.sh
. ./path.sh
. parse_options.sh
set -e

if [ $stage -le 1 ]; then
  echo "Stage $stage Begin! "
  # download the data.  Note: we're using the 100 hour setup for now; later in the script we'll download more and use it to train neural nets.
  for part in dev-clean test-clean dev-other test-other train-clean-100; do
    local/download_and_untar.sh $data $data_url $part
  done
  # download the LM resources
  local/download_lm.sh $lm_url data/local/lm
  echo "Stage $stage Finish! "
  stage=2
fi

if [ $stage -le 2 ]; then
  echo "Stage $stage Begin! "
  # format the data as Kaldi data directories
  for part in dev-clean test-clean dev-other test-other train-clean-100; do
    # use underscore-separated names in data directories.
    local/data_prep.sh $data/LibriSpeech/$part data/$(echo $part | sed s/-/_/g)
  done
  echo "Stage $stage Finish! "
  stage=3
fi

if [ $stage -le 3 ]; then
  echo "Stage $stage Begin! "
  # when the "--stage 3" option is used below we skip the G2P steps, and use the lexicon we have already downloaded from openslr.org/11/
  local/prepare_dict.sh --stage 3 --nj 80 --cmd "$train_cmd" data/local/lm data/local/lm data/local/dict_nosp
  utils/prepare_lang.sh data/local/dict_nosp "<UNK>" data/local/lang_tmp_nosp data/lang_nosp
  local/format_lms.sh --src-dir data/lang_nosp data/local/lm
  echo "Stage $stage Finish! "
  stage=4
fi

if [ $stage -le 4 ]; then
  echo "Stage $stage Begin! "
  # Create ConstArpaLm format language model for full 3-gram and 4-gram LMs
  utils/build_const_arpa_lm.sh data/local/lm/lm_tglarge.arpa.gz data/lang_nosp data/lang_nosp_test_tglarge
  utils/build_const_arpa_lm.sh data/local/lm/lm_fglarge.arpa.gz data/lang_nosp data/lang_nosp_test_fglarge
  echo "Stage $stage Finish! "
  stage=5
fi

# if [ $stage -le 5 ]; then
#   echo "Stage $stage Begin! "
#   # spread the mfccs over various machines, as this data-set is quite large.
#   if [[  $(hostname -f) ==  *.clsp.jhu.edu ]]; then
#     mfcc=$(basename mfccdir) # in case was absolute pathname (unlikely), get basename.
#     utils/create_split_dir.pl /export/b{02,11,12,13}/$USER/kaldi-data/egs/librispeech/s5/$mfcc/storage $mfccdir/storage
#   fi
#   echo "Stage $stage Finish! "
#   stage=6
# fi

if [ $stage -le 6 ]; then
  echo "Stage $stage Begin! "
  for part in dev_clean test_clean dev_other test_other train_clean_100; do
    steps/make_mfcc.sh --cmd "$train_cmd" --nj 40 data/$part exp/make_mfcc/$part $mfccdir
    steps/compute_cmvn_stats.sh data/$part exp/make_mfcc/$part $mfccdir
  done
  echo "Stage $stage Finish! "
  stage=7
fi

if [ $stage -le 7 ]; then
  echo "Stage $stage Begin! "
  # Make some small data subsets for early system-build stages. Note, there are 29k
  # utterances in the train_clean_100 directory which has 100 hours of data.
  # For the monophone stages we select the shortest utterances, which should make it
  # easier to align the data from a flat start.
  utils/subset_data_dir.sh --shortest data/train_clean_100 2000 data/train_2kshort
  utils/subset_data_dir.sh data/train_clean_100 5000 data/train_5k
  utils/subset_data_dir.sh data/train_clean_100 10000 data/train_10k
  echo "Stage $stage Finish! "
  stage=8
fi

if [ $stage -le 8 ]; then
  echo "Stage $stage Begin! "
  # train a monophone system
  steps/train_mono.sh --boost-silence 1.25 --nj 20 --cmd "$train_cmd" \
                      data/train_2kshort data/lang_nosp exp/mono
  # decode using the monophone model
  (
    utils/mkgraph.sh data/lang_nosp_test_tgsmall \
                     exp/mono exp/mono/graph_nosp_tgsmall
    for test in test_clean test_other dev_clean dev_other; do
      steps/decode.sh --nj 20 --cmd "$decode_cmd" exp/mono/graph_nosp_tgsmall \
                      data/$test exp/mono/decode_nosp_tgsmall_$test
    done
  )&
  echo "Stage $stage Finish! "
  stage=9
fi

if [ $stage -le 9 ]; then
  echo "Stage $stage Begin! "
  steps/align_si.sh --boost-silence 1.25 --nj 10 --cmd "$train_cmd" data/train_5k data/lang_nosp exp/mono exp/mono_ali_5k

  # train a first delta + delta-delta triphone system on a subset of 5000 utterances
  steps/train_deltas.sh --boost-silence 1.25 --cmd "$train_cmd" 2000 10000 data/train_5k data/lang_nosp exp/mono_ali_5k exp/tri1

  # decode using the tri1 model
  (
    utils/mkgraph.sh data/lang_nosp_test_tgsmall \
                     exp/tri1 exp/tri1/graph_nosp_tgsmall
    for test in test_clean test_other dev_clean dev_other; do
      steps/decode.sh --nj 20 --cmd "$decode_cmd" exp/tri1/graph_nosp_tgsmall \
                      data/$test exp/tri1/decode_nosp_tgsmall_$test
      steps/lmrescore.sh --cmd "$decode_cmd" data/lang_nosp_test_{tgsmall,tgmed} \
                         data/$test exp/tri1/decode_nosp_{tgsmall,tgmed}_$test
      steps/lmrescore_const_arpa.sh \
        --cmd "$decode_cmd" data/lang_nosp_test_{tgsmall,tglarge} \
        data/$test exp/tri1/decode_nosp_{tgsmall,tglarge}_$test
    done
  )&
  echo "Stage $stage Finish! "
  stage=10
fi

if [ $stage -le 10 ]; then
  echo "Stage $stage Begin! "
  steps/align_si.sh --nj 10 --cmd "$train_cmd" data/train_10k data/lang_nosp exp/tri1 exp/tri1_ali_10k

  # train an LDA+MLLT system.
  steps/train_lda_mllt.sh --cmd "$train_cmd" \
                          --splice-opts "--left-context=3 --right-context=3" 2500 15000 \
                          data/train_10k data/lang_nosp exp/tri1_ali_10k exp/tri2b

  # decode using the LDA+MLLT model
  (
    utils/mkgraph.sh data/lang_nosp_test_tgsmall exp/tri2b exp/tri2b/graph_nosp_tgsmall
    for test in test_clean test_other dev_clean dev_other; do
      steps/decode.sh --nj 20 --cmd "$decode_cmd" exp/tri2b/graph_nosp_tgsmall data/$test exp/tri2b/decode_nosp_tgsmall_$test
      steps/lmrescore.sh --cmd "$decode_cmd" data/lang_nosp_test_{tgsmall,tgmed} data/$test exp/tri2b/decode_nosp_{tgsmall,tgmed}_$test
      steps/lmrescore_const_arpa.sh --cmd "$decode_cmd" data/lang_nosp_test_{tgsmall,tglarge} data/$test exp/tri2b/decode_nosp_{tgsmall,tglarge}_$test
    done
  )&
  echo "Stage $stage Finish! "
  stage=11
fi

if [ $stage -le 11 ]; then
  echo "Stage $stage Begin! "
  # Align a 10k utts subset using the tri2b model
  steps/align_si.sh  --nj 10 --cmd "$train_cmd" --use-graphs true data/train_10k data/lang_nosp exp/tri2b exp/tri2b_ali_10k

  # Train tri3b, which is LDA+MLLT+SAT on 10k utts
  steps/train_sat.sh --cmd "$train_cmd" 2500 15000 data/train_10k data/lang_nosp exp/tri2b_ali_10k exp/tri3b

  # decode using the tri3b model
  (
    utils/mkgraph.sh data/lang_nosp_test_tgsmall exp/tri3b exp/tri3b/graph_nosp_tgsmall
    for test in test_clean test_other dev_clean dev_other; do
      steps/decode_fmllr.sh --nj 40 --cmd "$decode_cmd" exp/tri3b/graph_nosp_tgsmall data/$test exp/tri3b/decode_nosp_tgsmall_$test
      steps/lmrescore.sh --cmd "$decode_cmd" data/lang_nosp_test_{tgsmall,tgmed} data/$test exp/tri3b/decode_nosp_{tgsmall,tgmed}_$test
      steps/lmrescore_const_arpa.sh --cmd "$decode_cmd" data/lang_nosp_test_{tgsmall,tglarge} data/$test exp/tri3b/decode_nosp_{tgsmall,tglarge}_$test
    done
  )&
  echo "Stage $stage Finish! "
  stage=12
fi

if [ $stage -le 12 ]; then
  echo "Stage $stage Begin! "
  # align the entire train_clean_100 subset using the tri3b model
  steps/align_fmllr.sh --nj 20 --cmd "$train_cmd" \
    data/train_clean_100 data/lang_nosp \
    exp/tri3b exp/tri3b_ali_clean_100

  # train another LDA+MLLT+SAT system on the entire 100 hour subset
  steps/train_sat.sh  --cmd "$train_cmd" 4200 40000 data/train_clean_100 data/lang_nosp exp/tri3b_ali_clean_100 exp/tri4b

  # decode using the tri4b model
  (
    utils/mkgraph.sh data/lang_nosp_test_tgsmall \
                     exp/tri4b exp/tri4b/graph_nosp_tgsmall
    for test in test_clean test_other dev_clean dev_other; do
      steps/decode_fmllr.sh --nj 20 --cmd "$decode_cmd" \
                            exp/tri4b/graph_nosp_tgsmall data/$test \
                            exp/tri4b/decode_nosp_tgsmall_$test
      steps/lmrescore.sh --cmd "$decode_cmd" data/lang_nosp_test_{tgsmall,tgmed} \
                         data/$test exp/tri4b/decode_nosp_{tgsmall,tgmed}_$test
      steps/lmrescore_const_arpa.sh \
        --cmd "$decode_cmd" data/lang_nosp_test_{tgsmall,tglarge} \
        data/$test exp/tri4b/decode_nosp_{tgsmall,tglarge}_$test
      steps/lmrescore_const_arpa.sh \
        --cmd "$decode_cmd" data/lang_nosp_test_{tgsmall,fglarge} \
        data/$test exp/tri4b/decode_nosp_{tgsmall,fglarge}_$test
    done
  )&
  echo "Stage $stage Finish! "
  stage=13
fi

if [ $stage -le 13 ]; then
  echo "Stage $stage Begin! "
  # Now we compute the pronunciation and silence probabilities from training data,
  # and re-create the lang directory.
  steps/get_prons.sh --cmd "$train_cmd" \
                     data/train_clean_100 data/lang_nosp exp/tri4b
  utils/dict_dir_add_pronprobs.sh --max-normalize true \
                                  data/local/dict_nosp \
                                  exp/tri4b/pron_counts_nowb.txt exp/tri4b/sil_counts_nowb.txt \
                                  exp/tri4b/pron_bigram_counts_nowb.txt data/local/dict

  utils/prepare_lang.sh data/local/dict \
                        "<UNK>" data/local/lang_tmp data/lang
  local/format_lms.sh --src-dir data/lang data/local/lm

  utils/build_const_arpa_lm.sh \
    data/local/lm/lm_tglarge.arpa.gz data/lang data/lang_test_tglarge
  utils/build_const_arpa_lm.sh \
    data/local/lm/lm_fglarge.arpa.gz data/lang data/lang_test_fglarge

  # decode using the tri4b model with pronunciation and silence probabilities
  (
    utils/mkgraph.sh \
      data/lang_test_tgsmall exp/tri4b exp/tri4b/graph_tgsmall
    for test in test_clean test_other dev_clean dev_other; do
      steps/decode_fmllr.sh --nj 20 --cmd "$decode_cmd" \
                            exp/tri4b/graph_tgsmall data/$test \
                            exp/tri4b/decode_tgsmall_$test
      steps/lmrescore.sh --cmd "$decode_cmd" data/lang_test_{tgsmall,tgmed} \
                         data/$test exp/tri4b/decode_{tgsmall,tgmed}_$test
      steps/lmrescore_const_arpa.sh \
        --cmd "$decode_cmd" data/lang_test_{tgsmall,tglarge} \
        data/$test exp/tri4b/decode_{tgsmall,tglarge}_$test
      steps/lmrescore_const_arpa.sh \
        --cmd "$decode_cmd" data/lang_test_{tgsmall,fglarge} \
        data/$test exp/tri4b/decode_{tgsmall,fglarge}_$test
    done
  )&
  echo "Stage $stage Finish! "
  stage=14
fi

if [ $stage -le 14 ] && false; then
  echo "Stage $stage Begin! "
  # This stage is for nnet2 training on 100 hours; we're commenting it out
  # as it's deprecated.
  # align train_clean_100 using the tri4b model
  steps/align_fmllr.sh --nj 30 --cmd "$train_cmd" \
    data/train_clean_100 data/lang exp/tri4b exp/tri4b_ali_clean_100

  # This nnet2 training script is deprecated.
  local/nnet2/run_5a_clean_100.sh
  echo "Stage $stage Finish! "
  stage=15
fi

if [ $stage -le 15 ]; then
  echo "Stage $stage Begin! "
  local/download_and_untar.sh $data $data_url train-clean-360

  # now add the "clean-360" subset to the mix ...
  local/data_prep.sh $data/LibriSpeech/train-clean-360 data/train_clean_360
  steps/make_mfcc.sh --cmd "$train_cmd" --nj 40 data/train_clean_360 exp/make_mfcc/train_clean_360 $mfccdir
  steps/compute_cmvn_stats.sh data/train_clean_360 exp/make_mfcc/train_clean_360 $mfccdir

  # ... and then combine the two sets into a 460 hour one
  utils/combine_data.sh data/train_clean_460 data/train_clean_100 data/train_clean_360
  echo "Stage $stage Finish! "
  stage=16
fi

if [ $stage -le 16 ]; then
  echo "Stage $stage Begin! "
  # align the new, combined set, using the tri4b model
  steps/align_fmllr.sh --nj 40 --cmd "$train_cmd" \
                       data/train_clean_460 data/lang exp/tri4b exp/tri4b_ali_clean_460

  # create a larger SAT model, trained on the 460 hours of data.
  steps/train_sat.sh  --cmd "$train_cmd" 5000 100000 \
                      data/train_clean_460 data/lang exp/tri4b_ali_clean_460 exp/tri5b

  # decode using the tri5b model
  (
    utils/mkgraph.sh data/lang_test_tgsmall \
                     exp/tri5b exp/tri5b/graph_tgsmall
    for test in test_clean test_other dev_clean dev_other; do
      steps/decode_fmllr.sh --nj 20 --cmd "$decode_cmd" \
                            exp/tri5b/graph_tgsmall data/$test \
                            exp/tri5b/decode_tgsmall_$test
      steps/lmrescore.sh --cmd "$decode_cmd" data/lang_test_{tgsmall,tgmed} \
                         data/$test exp/tri5b/decode_{tgsmall,tgmed}_$test
      steps/lmrescore_const_arpa.sh \
        --cmd "$decode_cmd" data/lang_test_{tgsmall,tglarge} \
        data/$test exp/tri5b/decode_{tgsmall,tglarge}_$test
      steps/lmrescore_const_arpa.sh \
        --cmd "$decode_cmd" data/lang_test_{tgsmall,fglarge} \
        data/$test exp/tri5b/decode_{tgsmall,fglarge}_$test
    done
  )&
  echo "Stage $stage Finish! "
  stage=17
fi

if [ $stage -le 17 ]; then
  echo "Stage $stage Begin! "
  # prepare the remaining 500 hours of data
  local/download_and_untar.sh $data $data_url train-other-500

  # prepare the 500 hour subset.
  local/data_prep.sh $data/LibriSpeech/train-other-500 data/train_other_500
  steps/make_mfcc.sh --cmd "$train_cmd" --nj 40 data/train_other_500 exp/make_mfcc/train_other_500 $mfccdir
  steps/compute_cmvn_stats.sh data/train_other_500 exp/make_mfcc/train_other_500 $mfccdir

  # combine all the data
  utils/combine_data.sh data/train_960 data/train_clean_460 data/train_other_500
  echo "Stage $stage Finish! "
  stage=18
fi

if [ $stage -le 18 ]; then
  echo "Stage $stage Begin! "
  steps/align_fmllr.sh --nj 40 --cmd "$train_cmd" data/train_960 data/lang exp/tri5b exp/tri5b_ali_960

  # train a SAT model on the 960 hour mixed data.  Use the train_quick.sh script as it is faster.
  steps/train_quick.sh --cmd "$train_cmd" 7000 150000 data/train_960 data/lang exp/tri5b_ali_960 exp/tri6b
  # decode using the tri6b model
  (
    utils/mkgraph.sh data/lang_test_tgsmall exp/tri6b exp/tri6b/graph_tgsmall
    for test in test_clean test_other dev_clean dev_other; do
      steps/decode_fmllr.sh --nj 20 --cmd "$decode_cmd" exp/tri6b/graph_tgsmall data/$test exp/tri6b/decode_tgsmall_$test
      steps/lmrescore.sh --cmd "$decode_cmd" data/lang_test_{tgsmall,tgmed} data/$test exp/tri6b/decode_{tgsmall,tgmed}_$test
      steps/lmrescore_const_arpa.sh --cmd "$decode_cmd" data/lang_test_{tgsmall,tglarge} \
        data/$test exp/tri6b/decode_{tgsmall,tglarge}_$test steps/lmrescore_const_arpa.sh \
        --cmd "$decode_cmd" data/lang_test_{tgsmall,fglarge} data/$test exp/tri6b/decode_{tgsmall,fglarge}_$test
    done
  )&
  echo "Stage $stage Finish! "
  stage=19
fi

if [ $stage -le 19 ]; then
  echo "Stage $stage Begin! "
  # this does some data-cleaning. The cleaned data should be useful when we add
  # the neural net and chain systems. (although actually it was pretty clean already.)
  local/run_cleanup_segmentation.sh
  echo "Stage $stage Finish! "
  stage=20
fi

if [ $stage -le 20 ]; then
  echo "Stage $stage Begin! "
  # train and test nnet3 tdnn models on the entire data with data-cleaning.
  local/chain/run_tdnn.sh # set "--stage 11" if you have already run local/nnet3/run_tdnn.sh
  echo "Stage $stage Finish! "
  stage=21
fi

# The nnet3 TDNN recipe:
# local/nnet3/run_tdnn.sh # set "--stage 11" if you have already run local/chain/run_tdnn.sh

# Wait for decodings in the background
wait

if [ $stage -le 21 ]; then
  # write results to file
  if [ -f tdnn_results.txt ]; then
    rm tdnn_results.txt
  fi
  for x in exp/chain_cleaned1/tdnn_1_sp/decode_*; do
    grep WER $x/wer_* | utils/best_wer.sh >> tdnn_results.txt
  done
fi
