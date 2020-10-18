#-------------------------------------------------------------------------
# set S2RELEASE to the semantic scholar corpus release you want to use
# set SCRATCH to the scratch-dir location
#-------------------------------------------------------------------------
#
# option 1: Running on GPU server
# 
#   make all
#
#
# option 2: Running with SLURM GPU train job
#
# - adjust parameters for GPU jobs on your SLURM server
# - first prepare the data (to avoid wasting GPU time for that)
# - then train on GPU
# - finally assign reviewers
# 
#   make prepare
#   make train.gpujob
#   make assign
#
# for GPU jobs: adjust implict %.gpujob recipe
# set walltime with HPC_TIME (format = hh::mm)
#
#
# or run 3 different subsequent jobs:
#
#   make all-job
#-------------------------------------------------------------------------

AREACHAIRS ?= eacl2021-area-chairs.txt
SCRATCH    ?= scratch
S2RELEASE  ?= 2020-05-27
S2URL      := https://s3-us-west-2.amazonaws.com/ai2-s2-research-public/open-corpus

## training data
## - either ACL anthology (${SCRATCH}/acl-anthology.json)
## - or ACL anthology + additional papers of reviewers and authors

# TRAINDATA := ${SCRATCH}/acl-anthology.json
TRAINDATA := ${SCRATCH}/relevant-papers.json

PYTHON  ?= python


.PHONY: all
all: ${SCRATCH}/assignments.txt

.PHONY: prepare
prepare: ${SCRATCH}/abstracts.20k.sp.txt

.PHONY: train
train: ${SCRATCH}/similarity-model.pt

.PHONY: assign
assign: ${SCRATCH}/assignments.csv ${SCRATCH}/meta-assignments.csv \
	${SCRATCH}/assignments.txt ${SCRATCH}/meta-assignments.txt


##-----------------------------------------------------------
## submit a job in 3 steps
##
## (1) prepare data on CPU node
## (2) train a model on GPU node
## (3) assign reviewers on CPU node (with a bit more RAM)

.PHONY: all-job
all-job:
	${MAKE} prepare-and-train-job.cpujob

.PHONY: prepare-and-train-job
prepare-and-train-job: prepare
	${MAKE} train-and-assign-job.gpujob

.PHONY: train-and-assign-job
train-and-assign-job: train
	${MAKE} HPC_MEM=16g assign.cpujob

##-----------------------------------------------------------




## download S2 corpus

${SCRATCH}/s2/manifest.txt:
	mkdir -p ${dir $@}
	cd ${dir $@} && wget ${S2URL}/${S2RELEASE}/manifest.txt

${SCRATCH}/s2: ${SCRATCH}/s2/manifest.txt
	cd ${dir $@} && wget -B ${S2URL}/${S2RELEASE}/ -i manifest.txt

s2: ${SCRATCH}/s2
	-ln -s $< $@


## grep for ACL anthology

${SCRATCH}/acl-anthology.json: s2
	zcat s2/s2-corpus*.gz | grep aclweb.org > $@



## prepare training data (tokenized paper abstracts)

STS:
	bash download_sts17.sh

${SCRATCH}/abstracts.txt: ${TRAINDATA} STS
	${PYTHON} tokenize_abstracts.py --infile $< --outfile $@

${SCRATCH}/abstracts.20k.sp.txt: ${SCRATCH}/abstracts.txt
	${PYTHON} sentencepiece_abstracts.py \
		--infile $< \
		--vocab-size 20000 \
		--model-name scratch/abstracts.sp.20k \
		--outfile $@


## train the model

${SCRATCH}/similarity-model.pt: ${SCRATCH}/abstracts.20k.sp.txt
	${PYTHON} -u train_similarity.py --data-file $< \
		--model avg --dim 1024 --epochs 20 --ngrams 0 --share-vocab 1 --dropout 0.3 \
		--outfile $@ \
		--batchsize 64 --megabatch-size 1 \
		--megabatch-anneal 10 --seg-length 1 \
		--sp-model scratch/abstracts.sp.20k.model 2>&1 | \
	tee scratch/training.log



## convert CSV files into JSON

${SCRATCH}/submissions.jsonl: ${SCRATCH}/Profile_Information.csv ${SCRATCH}/Submission_Information.csv ${SCRATCH}/Bid_Information.csv
	${PYTHON} softconf_extract.py \
		--profile_in=${word 1,$^} \
		--submission_in=${word 2,$^} \
		--bid_in=${word 3,$^} \
		--reviewer_out=${SCRATCH}/all-reviewers.jsonl \
		--bid_out=${SCRATCH}/cois.npy \
		--submission_out=$@ |\
	tee $(@:.jsonl=.log)

${SCRATCH}/all-reviewers.jsonl: ${SCRATCH}/Profile_Information.csv
	${PYTHON} softconf_extract.py \
		--profile_in=$< \
		--reviewer_out=$@ |\
	tee $(@:.jsonl=.log)


## query for papers by authors and reviewers

${SCRATCH}/relevant-papers.ids: ${SCRATCH}/all-reviewers.jsonl
	${PYTHON} s2_query_paperids.py --reviewer_file $< > $@

${SCRATCH}/relevant-papers.json: ${SCRATCH}/relevant-papers.ids s2
	zcat s2/s2-corpus-*.gz | \
	perl s2_grep_papers.pl -i $< -q 'aclweb\.org' > $@ 2> $(@:.json=.log)

## problems with querying for papers: download limits and timeouts 
## --> extract from s2 database instead (see above)
#
# ${SCRATCH}/relevant-papers.json: ${SCRATCH}/relevant-papers.ids ${SCRATCH}/acl-anthology.json
#	${PYTHON} s2_query_papers.py \
#		--paperid_file $< \
#		--db_file ${word 2,$^} > $@



## find best assignments

${SCRATCH}/reviewers.jsonl: ${SCRATCH}/all-reviewers.jsonl ${AREACHAIRS}
	perl grep_reviewers.pl -v -i ${AREACHAIRS} < $< > $@

${SCRATCH}/meta-reviewers.jsonl: ${SCRATCH}/all-reviewers.jsonl ${AREACHAIRS}
	perl grep_reviewers.pl -i ${AREACHAIRS} $< > $@


${SCRATCH}/assignments.jsonl: 	${SCRATCH}/relevant-papers.json \
				${SCRATCH}/submissions.jsonl \
				${SCRATCH}/reviewers.jsonl \
				${SCRATCH}/similarity-model.pt
	${PYTHON} suggest_reviewers.py \
		--db_file=$< \
		--submission_file=${word 2,$^} \
		--reviewer_file=${word 3,$^} \
		--model_file=${word 4,$^} \
		--min_papers_per_reviewer=1 \
		--max_papers_per_reviewer=5 \
		--reviews_per_paper=3 \
		--bid_file ${SCRATCH}/cois.npy \
		--track \
		--suggestion_file=$@ | \
	tee $(@:.jsonl=.log)

${SCRATCH}/assignments.txt: ${SCRATCH}/assignments.jsonl
	python suggest_to_text.py < $< > $@

${SCRATCH}/assignments.csv: ${SCRATCH}/assignments.jsonl
	${PYTHON} softconf_package.py --split_by_track --suggestion_file $< --softconf_file $@



${SCRATCH}/meta-assignments.jsonl: 	${SCRATCH}/relevant-papers.json \
					${SCRATCH}/submissions.jsonl \
					${SCRATCH}/meta-reviewers.jsonl \
					${SCRATCH}/similarity-model.pt
	${PYTHON} suggest_reviewers.py \
		--db_file=$< \
		--submission_file=${word 2,$^} \
		--reviewer_file=${word 3,$^} \
		--model_file=${word 4,$^} \
		--min_papers_per_reviewer=3 \
		--max_papers_per_reviewer=10 \
		--reviews_per_paper=1 \
		--track \
		--suggestion_file=$@ | \
	tee $(@:.jsonl=.log)

${SCRATCH}/meta-assignments.txt: ${SCRATCH}/meta-assignments.jsonl
	python suggest_to_text.py < $< > $@

${SCRATCH}/meta-assignments.csv: ${SCRATCH}/meta-assignments.jsonl
	${PYTHON} softconf_package.py --split_by_track --suggestion_file $< --softconf_file $@


#############################################
#  create a SLURM GPU job
#############################################

HPC_MEM       ?= 4g
HPC_GPU_QUEUE ?= gpu
HPC_CPU_QUEUE ?= small
HPC_TIME      ?= 24:00
GPU           ?= v100
NR_GPUS       ?= 1

## for puhti @ CSC/Finland
ifeq (${shell hostname --domain 2>/dev/null},bullx)
  HPC_ACCOUNT := project_2002688
  MODULES     := pytorch intel-mkl
endif

%.gpujob:
	echo '#!/bin/bash -l'                          > $@
	echo '#SBATCH -J "${@:.gpujob=}"'             >> $@
	echo '#SBATCH -o ${@:.gpujob=}.out.%j'        >> $@
	echo '#SBATCH -e ${@:.gpujob=}.err.%j'        >> $@
	echo '#SBATCH --mem=${HPC_MEM}'               >> $@
	echo '#SBATCH -n 1'                           >> $@
	echo '#SBATCH -N 1'                           >> $@
	echo '#SBATCH -p ${HPC_GPU_QUEUE}'            >> $@
	echo '#SBATCH -t ${HPC_TIME}:00'              >> $@
	echo '#SBATCH --gres=gpu:${GPU}:${NR_GPUS}'   >> $@
ifdef HPC_ACCOUNT
	echo '#SBATCH --account=${HPC_ACCOUNT}'       >> $@
endif
ifdef EMAIL
	echo '#SBATCH --mail-type=END'                >> $@
	echo '#SBATCH --mail-user=${EMAIL}'           >> $@
endif
ifdef MODULES
	echo "module load ${MODULES}"                 >> $@
	echo 'module list' >> $@
endif
	echo 'cd $${SLURM_SUBMIT_DIR:-.}'             >> $@
	echo 'pwd'                                    >> $@
	echo 'echo "Starting at `date`"'              >> $@
	echo 'srun ${MAKE} ${MAKEARGS} ${@:.gpujob=}' >> $@
	echo 'echo "Finishing at `date`"'             >> $@
	sbatch $@



%.cpujob:
	echo '#!/bin/bash -l'                          > $@
	echo '#SBATCH -J "${@:.cpujob=}"'             >> $@
	echo '#SBATCH -o ${@:.cpujob=}.out.%j'        >> $@
	echo '#SBATCH -e ${@:.cpujob=}.err.%j'        >> $@
	echo '#SBATCH --mem=${HPC_MEM}'               >> $@
	echo '#SBATCH -n 1'                           >> $@
	echo '#SBATCH -N 1'                           >> $@
	echo '#SBATCH -p ${HPC_CPU_QUEUE}'            >> $@
	echo '#SBATCH -t ${HPC_TIME}:00'              >> $@
ifdef HPC_ACCOUNT
	echo '#SBATCH --account=${HPC_ACCOUNT}'       >> $@
endif
ifdef EMAIL
	echo '#SBATCH --mail-type=END'                >> $@
	echo '#SBATCH --mail-user=${EMAIL}'           >> $@
endif
ifdef MODULES
	echo "module load ${MODULES}"                 >> $@
	echo 'module list' >> $@
endif
	echo 'cd $${SLURM_SUBMIT_DIR:-.}'             >> $@
	echo 'pwd'                                    >> $@
	echo 'echo "Starting at `date`"'              >> $@
	echo 'srun ${MAKE} ${MAKEARGS} ${@:.cpujob=}' >> $@
	echo 'echo "Finishing at `date`"'             >> $@
	sbatch $@
