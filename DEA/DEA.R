#!/usr/bin/Rscript
#Script to automate differential expression analysis using the following R algorithms: DESeq2, edgeR and limma
#Based on manuals, pieces of code found on the internet and helpful comments of colleagues
###Required input is:###
#1) A sampleInfo File matching the samples containing at least the fields 'file', 'sample' and condition' with additional covariates (reference level condition == "CON")
#2) An annotation file in gtf format matching the reference genome used for alignment
######

#Author: wdecoster
#Twitter: @wouter_decoster
#Questions: https://www.biostars.org/t/DEA.R/
version="0.7.1"

sanityCheck <- function() {
	arguments <- unlist(strsplit(commandArgs(trailingOnly = TRUE)," "))
	if (length(arguments) == 0) {usage()}
	if (length(arguments) != 2 && ! arguments[1] %in% c("install", "citations", "version", "--version", "-v")) { usage() }
	inputdata <- list()
	if (tolower(arguments[1]) == "install") { install() }
	if (tolower(arguments[1]) == "citations") { citations() }
	if (tolower(arguments[1]) %in% c("version", "--version", "-v")) {
		cat(paste("\nDEA.R version", version, "\n\n", sep=" "))
		quit()
		}
	library(parallel)
	inputdata$cores <- min(detectCores() - 1, 12)
	inputdata$annotation <- arguments[2]
	if (! file.exists(inputdata$annotation)) {giveError("FATAL: Could not find the annotation file, check if path is correct.")	}
	inputdata$sampleInfo <- checkSampleInfo(arguments[1])
	inputdata$gender <- ifelse("gender" %in% names(inputdata$sampleInfo), TRUE, FALSE)
	inputdata$PE <- ifelse(as.character(inputdata$sampleInfo$sequencing[1]) == "PE", TRUE, FALSE)
	inputdata$strand <- switch(
		as.character(inputdata$sampleInfo$strandedness[1]),
		'unstranded' = 0,
		'stranded' = 1,
		'reverse' = 2)
	inputdata$design <- makedesign(inputdata$sampleInfo)
	inputdata$counts <- getCounts(inputdata=inputdata)
	return(inputdata)
	}

giveError <- function(message){
	cat(paste("\n\n", message, "\n\n", sep=""))
	quit()
	}

usage <- function(){giveError("USAGE: DEA.R <sample info file> <annotation.gtf>.\nOther run mode options are 'install', 'citations' or 'version'")}

makedesign <- function(sampleInfo) {
	covariates <- names(sampleInfo)[which(! names(sampleInfo) %in% c("file", "condition", "sample", "subcondition", "sequencing", "strandedness"))]
	design <- formula(paste("~", paste(c(covariates, "condition"), sep="", collapse=" + ")))
	return(design)
	}

checkSampleInfo <- function(sampleInfoFile) {
	if (!file.exists(sampleInfoFile)) {giveError("ARGUMENT ERROR:\nFile provided as sample info file doesn't exist or path is incorrect.") }
	sampleInfo <- read.table(sampleInfoFile, header=T, stringsAsFactors=F)
	if (!"condition" %in% names(sampleInfo)) {
		giveError("SAMPLEINFO ERROR:\nCould not find required field <condition> in sample info file.")}
	if (min(table(sampleInfo$condition)) < 3) {
		giveError("SAMPLEINFO ERROR:\nLess than 3 replicates in smallest group from <condition>.")}
	if (! "CON" %in% sampleInfo$condition) {
		giveError("SAMPLEINFO ERROR:\n<CON> is a required value in the field <condition>")}
	if (length(unique(sampleInfo$condition)) < 2) {
		giveError("SAMPLEINFO ERROR:\nfield <condition> needs at least two different values/groups.")} #Need at least two levels
	if (!"sample" %in% names(sampleInfo)) {
		giveError("SAMPLEINFO ERROR:\nCould not find required field <sample> in sample info file.")}
	if (anyDuplicated(sampleInfo$sample)) {
		giveError("SAMPLEINFO ERROR:\nValues in field <sample> in sample info file are not unique.")} #Sample names should be unique
	if (!"file" %in% names(sampleInfo)) {
		giveError("SAMPLEINFO ERROR:\nCould not find required field <file> in sample info file.")}
	if (anyDuplicated(sampleInfo$file)) {
		giveError("SAMPLEINFO ERROR:\nValues in field <file> in sample info file are not unique.")} #File names should be unique
	for (path in sampleInfo$file) {
		if (! file.exists(path)) {giveError(paste("Incorrect path to", path, "\nFile not found."))}}
	if (!"sequencing" %in% names(sampleInfo)) {
		giveError("SAMPLEINFO ERROR:\nCould not find required field <sequencing> in sample info file.")}
	if (!length(unique(sampleInfo$sequencing)) == 1) {
		giveError("SAMPLEINFO ERROR:\nOnly one type of sequencing (either PE or SE) is supported in field <sequencing>.")}
	if (! unique(sampleInfo$sequencing) %in% c("PE", "SE")) {
		giveError("SAMPLEINFO ERROR:\nInput in field <sequencing> should be either PE or SE, and only one type supported per experiment.")}
	if (!"strandedness" %in% names(sampleInfo)) {
		giveError("SAMPLEINFO ERROR:\nCould not find required field <strandedness> in sample info file.")}
	if (!length(unique(sampleInfo$strandedness)) == 1) {
		giveError("SAMPLEINFO ERROR:\nOnly one type of strandedness (either unstranded, stranded or reverse) is supported in field <stranded>.")}
	if (! unique(sampleInfo$strandedness) %in% c("unstranded", "stranded", "reverse")) {
		giveError("SAMPLEINFO ERROR:\nInput in field <strandedness> should be either unstranded, stranded or reverse, and only one type supported per experiment.")}
	if ("gender" %in% names(sampleInfo)) {
		if (! all(unique(sampleInfo$gender) %in% c("m", "f", "u"))) {
			giveError("SAMPLEINFO ERROR:\nOnly the values m [male], f [female] and u [unknown] are supported in field <gender>.")}
		}
	for (field in names(sampleInfo)) {
		if (! field %in% c("file", "sample")) {
			sampleInfo[,field] <- as.factor(sampleInfo[,field])
			}
		}
	return(sampleInfo)
	}

getCounts <- function(inputdata) {
	if (file.exists("FeatureCounts_RawCounts.RData")){
		load("FeatureCounts_RawCounts.RData")
		cat("Found RData countsfile, using this one without perform counting again.\n")
		if (! all(colnames(counts) == inputdata$sampleInfo$sample)) {
			giveError("ERROR:\nSaved file <FeatureCounts_RawCounts.RData> doesn't match with sample info file.")}
	} else {
		cat("Performing counting with featureCounts from Rsubread.\n")
		suppressMessages(library(Rsubread))
		capture.output(
			counts <- featureCounts(inputdata$sampleInfo$file,
				annot.ext=inputdata$annotation,
				isGTFAnnotationFile=TRUE,
				GTF.featureType="exon",
				strandSpecific=inputdata$strand, # unstranded: 0, stranded: 1, reversely stranded: 2
				nthreads=inputdata$cores,
				isPairedEnd=inputdata$PE,
				countMultiMappingReads=FALSE),
			file = "FeatureCounts.log")
		cat("Counting complete, creating count-statistics.\n")
		colnames(counts$counts) <- inputdata$sampleInfo$sample
		write.table(
			x=cbind(feature=rownames(counts$counts), counts$counts),
			file="FeatureCounts_RawCounts.txt",
			quote=F,
			sep="\t",
			row.names=F)
		countStats(
			statdat=counts$stat,
			samples=inputdata$sampleInfo$sample,
			inputdata=inputdata,
			counts=counts$counts)
		counts <- counts$counts
		save(counts, file="FeatureCounts_RawCounts.RData")
		}
	return(counts)
	}

countStats <- function(statdat, samples, inputdata, counts) {
	#Creating relative stats by dividing each number by the sum of Assigned, Unassigned_Ambiguity, Unassigned_NoFeaturesUnassigned_NoFeatures
	relativeStats <- cbind(
						Status = paste(statdat$Status, "relative", sep="_"),
						statdat[, 2:ncol(statdat)] / rep(as.numeric(statdat[1,2:ncol(statdat)] + statdat[2,2:ncol(statdat)] + statdat[4,2:ncol(statdat)]), each=11)
						)
	completeStats <- rbind(statdat, relativeStats)
	p <- ggplot(data=data.frame(Unassigned_NoFeatures_relative = as.numeric(relativeStats[4,2:ncol(relativeStats)])), aes(x=1, y=Unassigned_NoFeatures_relative)) +
		geom_violin() +
		geom_dotplot(binaxis='y', stackdir='center', position="dodge") +
		ggtitle("Fraction of reads not mapping to a feature") +
		theme(axis.title.x = element_blank(),
			axis.ticks.x=element_blank(),
			axis.text.x = element_blank(),
			panel.grid.major.x = element_blank(),
			plot.title = element_text(hjust = 0.5),
			legend.position="none") +
		ylab("Fraction of reads")
	suppressMessages(ggsave("FeatureCounts_NoFeaturePlot.jpeg", p))
	rownames(completeStats) <- completeStats$Status
	completeStats$Status <- NULL
	names(completeStats) <- samples
	write.table(
		x=cbind(Sample = colnames(completeStats), t(completeStats)),
		file="FeatureCounts_CountingStatistics.txt",
		quote=F,
		sep="\t",
		row.names=F)
	if (inputdata$gender) {	genderPlots(inputdata$sampleInfo$gender, counts) }
	}

is.between <- function(x, a) {(x - a[1])  *  (a[2] - x) > 0}

addLabel <- function(data) {
	mVal <- data[data$gender=="m",'gene']
	mQuantil <- quantile(mVal, c(.10, .90))
	fVal <- data[data$gender=="f",'gene']
	fQuantil <- quantile(fVal, c(.10, .90))
	InRange <- c(rownames(data[data$gender == "m",])[is.between(mVal, fQuantil)], rownames(data[data$gender == "f",])[is.between(fVal, mQuantil)])
	data$sample <- rownames(data)
	data$label <- ifelse(rownames(data) %in% InRange, 1, 0)
	return(data)
	}

genderPlots <- function(genders, counts) {
	#Making gender specific plots based on https://www.ncbi.nlm.nih.gov/pubmed/23829492
	genderSpecificGenes = data.frame(
		ens = c('ENSG00000129824', 'ENSG00000198692', 'ENSG00000067048', 'ENSG00000012817', 'ENSG00000229807'),
		symbol = c('RPS4Y1', 'EIF1AY', 'DDX3Y', 'KDM5D', 'XIST'),
		stringsAsFactors = F)
	genderSpecificCounts <- t(counts[rownames(counts) %in% genderSpecificGenes$ens,])
	for (gene in genderSpecificGenes$ens) {
		data = addLabel(data.frame(gene = genderSpecificCounts[,gene], gender = genders))
		symbol = genderSpecificGenes[genderSpecificGenes$ens == gene, "symbol"]
		p <- ggplot(data, aes(x=gender, y=gene)) +
			geom_violin() +
			geom_dotplot(
				binaxis='y',
				stackdir='center',
				dotsize=0.2,
				binwidth=0.025,
				position="dodge") +
			ggtitle(paste("Reads in gender specific gene", symbol, sep=" ")) +
			theme(axis.title.x = element_blank(),
				axis.ticks.x=element_blank(),
				panel.grid.major.x = element_blank(),
				plot.title = element_text(hjust = 0.5),
				legend.position="none") +
			ylab("Raw number of reads") +
			geom_label_repel(
				data=data[data$label == 1,],
				aes(label=sample),
				point.padding=unit(1, "lines")
				)
		suppressMessages(ggsave(paste("GenderSpecificGene", symbol , "jpeg", sep="."), p))
			}
		}

install <- function() {
	update.packages()
	install.packages(c("devtools", "dplyr", "ggplot2", "ggrepel", "VennDiagram"), quiet=T, repos='http://cran.rstudio.com/')
	devtools::install_github("stephenturner/annotables")
	source("https://bioconductor.org/biocLite.R")
	biocLite(c("DESeq2", "edgeR", "Rsubread	"))
	}

citations <- function() {
	cat("Packages used by this script with their citation:\n")
	for (package in c("ggplot2", "ggrepel", "DESeq2", "edgeR", "limma", "pheatmap", "RColorBrewer", "dplyr")){
		suppressMessages(library(package, character.only = TRUE))
		cat(paste(package, ":\n", sep=""))
		cat(unlist(citation(package)))
		cat('\n\n')
		}
	cat("Packages used by this script with no citation provided:\n")
	for (package in c("BiocParallel", "annotables", "genefilter")) {
		cat(paste(package, "\n", sep=""))
		}
	quit()
	}

proc_limma_voom <- function(inputdata) {
	design <- model.matrix(inputdata$design, data=inputdata$sampleInfo)
	dge <- calcNormFactors(DGEList(counts=inputdata$counts))
	vwts <- voomWithQualityWeights(dge, design=design, normalization="none") #For outliers, use sample quality weights
	normalizedCounts <- ens2symbol(
		dearesult=vwts$E,
		columnsOfInterest=c("gene", colnames(vwts$E), "symbol"),
		colnames=c("gene", colnames(vwts$E), "symbol"))
	write.table(
		x=normalizedCounts,
		file="Limma-voom_normalizedcounts.txt",
		sep="\t",
		row.names=FALSE,
		quote=FALSE)
	write.table(
		x=normalizedCounts[,c("gene", "symbol")],
		file="Limma-voom_consideredgenes.txt",
		sep="\t",
		row.names=FALSE,
		quote=FALSE)
	#makePCA(vwts$E, "Limma-voom")
	fit <- eBayes(lmFit(vwts))
	degTable <- topTable(fit,number=Inf, coef=ncol(design))
	output <- ens2symbol(
		dearesult=degTable[order(degTable$adj.P.Val),],
		columnsOfInterest=c('gene', 'logFC', 'P.Value', 'adj.P.Val', 'symbol'),
		colnames=c("gene", "logFC", "pvalue", "padj", "symbol"))
	makeVolcanoPlot(
		input=mutate(output, sig=ifelse(output$padj<0.1, "padj<0.1", "Not Sig")),
		toolname="Limma-voom",
		names=c("padj<0.1", "Not Sig"))
	DEG <- subset(output, padj < 0.1)
	cat(paste("Found", nrow(subset(DEG, logFC > 0)), "upregulated genes and", nrow(subset(DEG, logFC < 0)), "downregulated genes using Limma-voom.\n", collapse=" "))
	write.table(
		x=as.data.frame(output),
		file="Limma-voom_differential_expression.txt",
		sep="\t",
		row.names=FALSE,
		quote=FALSE)
	write.table(
		x=as.data.frame(DEG[,c("gene", "symbol")]),
		file="Limma-voom_DEG.txt",
		sep="\t",
		col.names=FALSE,
		row.names=FALSE,
		quote=FALSE)
	return(DEG$gene)
	}


proc_deseq2 <- function(inputdata) {
	register(MulticoreParam(inputdata$cores))
	deseqdata <- DESeqDataSetFromMatrix(
		countData=inputdata$counts,
		colData=inputdata$sampleInfo,
		design=inputdata$design)
	dds <- deseqdata[rowSums(counts(deseqdata)) > 1,] #To prefilter the data and remove lowest counts
	dds$condition <- relevel(dds$condition, ref="CON")
	dds <- DESeq(dds, quiet=TRUE, parallel=TRUE)
	exploratoryDataAnalysisDESeq(dds)
	contrasts <- levels(dds$condition)
	for (group in contrasts[contrasts != "CON"]) {
		DEG <- getDESeqDEAbyContrast(dds, group)
		}
	return(DEG)
	}


exploratoryDataAnalysisDESeq <- function(dds) {
	jpeg('DESeq2_MAplot.jpeg', width=8, height=8, units="in", res=500)
	DESeq2::plotMA(dds, main="DESeq2", ylim=c(-2,2))
	dev.off()
	jpeg(
		filename='DESeq2_Dispersionplot.jpeg',
		width=8,
		height=8,
		units="in",
		res=500)
	plotDispEsts(dds)
	dev.off()
	rld <- rlogTransformation(dds, blind=FALSE)
	normcounts = assay(rld)
	rlddf <- data.frame(normcounts)
	rownames(rlddf) <- names(dds)
	rlddf <- ens2symbol(
		dearesult=rlddf,
		columnsOfInterest=c("gene", colnames(inputdata$counts), "symbol"),
		colnames=c("gene", colnames(inputdata$counts), "symbol"))
	makeHeatMap(normcounts, "DESeq2", paste(rld$condition, rld$sampleR, sep="-"))
	#makePCA(normcounts, "DESeq2")
	write.table(
		x=as.data.frame(rlddf),
		file="DESeq2_rlognormalizedcounts.txt",
		sep="\t",
		row.names=FALSE,
		quote=FALSE)
	write.table(
		x=rlddf[,c("gene", "symbol")],
		file="DESeq2_genesconsidered.txt",
		row.names=FALSE,
		quote=FALSE)
	}


getDESeqDEAbyContrast <- function(dds, group) {
	contrast <- paste("CONvs", group, sep="")
	res <- results(dds, parallel=TRUE, addMLE=T, contrast=c("condition", group, "CON"))
	cat('\n\nSummary data from DESeq2 for ', contrast, ':', sep="")
	summary(res)
	output <- ens2symbol(
		dearesult=res[order(res$padj),],
		columnsOfInterest=c("gene", "log2FoldChange", "lfcMLE", "pvalue", "padj", "symbol"),
		colnames=c("gene", "logFC", "logFC-unshrunken", "pvalue", "padj", "symbol"))
	write.table(
		x=as.data.frame(output),
		file=paste("DESeq2", contrast, "differential_expression.txt", sep="_"),
		sep="\t",
		row.names=FALSE,
		quote=FALSE)
	DEG <- as.data.frame(subset(output, padj < 0.1)[,c("gene", "symbol")])
	write.table(
		x=DEG,
		file=paste("DESeq2", contrast, "DEG.txt", sep="_"),
		sep="\t",
		col.names=FALSE,
		row.names=FALSE,
		quote=FALSE)
	makeVolcanoPlot(
		input=mutate(output, sig=ifelse(output$padj<0.1, "padj<0.1", "Not Sig")),
		toolname=paste("DESeq2", contrast, sep="_"),
		names=c("padj<0.1", "Not Sig"))
	jpeg(
		filename=paste('DESeq2', contrast, 'Histogram_pvalues.jpeg', sep="_"),
		width=8,
		height=8,
		units="in",
		res=500)
	hist(output$pvalue, main="Histogram of pvalues")
	dev.off()
	return(DEG$gene)
	}

proc_edger <- function(inputdata) {
	design <- model.matrix(inputdata$design, data=inputdata$sampleInfo)
	d <- DGEList(
		counts=data.matrix(inputdata$counts),
		group=inputdata$sampleInfo$condition)
	d$samples$group <- relevel(d$samples$group, ref="CON")
	dlim <- d[rowSums(cpm(d)>0.5) >= min(table(inputdata$sampleInfo$condition)) - 1,]
	disp <- estimateDisp(calcNormFactors(dlim), design) #Common dispersion and tagwise dispersions in one run
	rownames(design) <- colnames(disp)
	fit <- glmFit(disp,design) #Likelihood ratio tests
	deg <- glmLRT(fit, coef=ncol(fit$design))
	exploratoryDataAnalysisedgeR(deg, disp)
	output <- ens2symbol(
		dearesult=topTags(deg, n=nrow(deg$counts))$table,
		columnsOfInterest=c('gene', 'logFC', 'PValue', 'FDR', 'symbol'),
		colnames=c("gene", "logFC", "pvalue", "FDR", "symbol"))
	DEG <- subset(output, FDR < 0.1)
	write.table(
		x=output,
		file="edgeR_differential_expression.txt",
		sep="\t",
		row.names=FALSE,
		quote=FALSE)
	write.table(
		x=as.data.frame(DEG[,c("gene","symbol")]),
		file="edgeR_DEG.txt",
		sep="\t",
		col.names=FALSE,
		row.names=FALSE,
		quote=FALSE)
	cat(paste("Found", nrow(subset(DEG, logFC > 0)), "upregulated genes and", nrow(subset(DEG, logFC < 0)), "downregulated genes with edgeR-glmLRT.\n", collapse=" "))
	makeVolcanoPlot(
		input=mutate(output, sig=ifelse(output$FDR<0.1, "FDR<0.1", "Not Sig")),
		toolname="edgeR",
		names=c("FDR<0.1", "Not Sig"))
	return(DEG$gene)
	}

exploratoryDataAnalysisedgeR <- function(deg, disp){
	jpeg(
		filename='edgeR_MAplot.jpeg',
		width=8,
		height=8,
		units="in",
		res=500)
	plotSmear(deg, de.tags=rownames(disp)[as.logical(decideTestsDGE(deg))])
	abline(h=c(-1, 1), col="blue")
	dev.off()
	jpeg(
		filename='edgeR_dispersionPlot.jpeg',
		width=8,
		height=8,
		units="in",
		res=500)
	plotBCV(disp)
	dev.off()
	normalizedCounts <- cpm(disp)
	normalizedCounts_named <- ens2symbol(
		dearesult=normalizedCounts,
		columnsOfInterest=c("gene", colnames(normalizedCounts), "symbol"),
		colnames=c("gene", colnames(normalizedCounts), "symbol"))
	#makePCA(normalizedCounts)
	write.table(
		x=normalizedCounts_named,
		file="edgeR_normalizedCounts_cpm.txt",
		sep="\t",
		col.names=TRUE,
		row.names=FALSE,
		quote=FALSE)
	write.table(
		x=normalizedCounts_named[,c("gene", "symbol")],
		file="edgeR_genesconsidered.txt",
		sep="\t",
		col.names=TRUE,
		row.names=FALSE,
		quote=FALSE)
	}

ens2symbol <- function(dearesult, columnsOfInterest, colnames) { #convert ensembl identifiers to gene symbols using 'annotables', select columns and rename
	if (substr(rownames(dearesult)[1], 1, 4) == 'ENSG') {
		output <- cbind(gene=row.names(dearesult), as.data.frame(dearesult), stringsAsFactors=FALSE) #To convert the row names (features) to a column in the dataframe.
		output$symbol=sapply(sapply(strsplit(output$gene,","), function(x) unique(grch37[grch37$ensgene %in% x,"symbol"])), paste, collapse=",") #Comma separated overlapping features are matched to gene symbols and repasted together
	} else {
		output <- cbind(gene=row.names(dearesult), as.data.frame(dearesult), symbol='NA')
	}
	output <- output[,columnsOfInterest]
	colnames(output) <- colnames
	return(output)
	}

makeHeatMap <- function(normcounts, proc, names){
	sampleDists <- dist(t(normcounts))
	sampleDistMatrix <- as.matrix(sampleDists)
	rownames(sampleDistMatrix) <- names
	colnames(sampleDistMatrix) <- NULL
	jpeg(
		filename=paste(proc, 'SamplesHeatMap_normalizedcounts.jpeg', sep="_"),
		width=8,
		height=8,
		units="in",
		res=500)
	pheatmap(
		mat=sampleDistMatrix,
		clustering_distance_rows=sampleDists,
		clustering_distance_cols=sampleDists,
		col=colorRampPalette( rev(brewer.pal(9, "Blues")) )(255),
		fontsize_row=6)
	dev.off()
	}

makePCA <- function(normcounts, proc) {
	rv <- rowVars(normcounts)
	select <- order(rv, decreasing = TRUE)[seq_len(min(500, length(rv)))]
	pca <- prcomp(normcounts[select, ])
	percentVar <- pca$sdev^2 / sum( pca$sdev^2 )
	scree_plot <- data.frame(percentVar)
	scree_plot[1:10,2]<- c(1:10)
	colnames(scree_plot)<-c("variance","component_number")
	scree <- ggplot(scree_plot[1:10,], mapping=aes(x=component_number, y=variance)) +
		geom_bar(stat="identity")
	suppressMessages(ggsave(paste(proc, 'PCA_scree.jpeg', sep="_"), scree, device="jpeg"))
	pcadata <- plotPCA(normcounts, intgroup=c("condition"), returnData=TRUE)
	percentVar <- round(100 * attr(pcadata, "percentVar"))
	pca <- ggplot(pcadata, aes(PC1, PC2, color=condition, shape=condition)) +
		geom_point(size=3) +
		xlab(paste0("PC1: ",percentVar[1],"% variance")) +
		ylab(paste0("PC2: ",percentVar[2],"% variance"))
	suppressMessages(ggsave(paste(proc, 'PCAplot_normalizedcounts.jpeg', sep="_"), pca, device = "jpeg"))
	}

makeVolcanoPlot <- function(input, toolname, names) {
	colours = c("red", "black")
	names(colours) = names
	volc = ggplot(input, aes(logFC, -log10(pvalue))) +
	scale_color_manual(values=colours) +
		geom_point(aes(col=sig)) +
		ggtitle(toolname)
	if (substr(input$gene[1], 1, 4) == 'ENSG'){
		volc + geom_text_repel(data=head(input, 20), aes(label=symbol)) #If ENSG is present, the results were converted to symbol notation earlier and can use these
	} else {
		volc + geom_text_repel(data=head(input, 20), aes(label=gene)) }
	suppressMessages(ggsave(paste(toolname, "Volcanoplot.jpeg", sep="_"), device="jpeg"))
	}

makeVennDiagram <- function(set1, set2, set3) {
	jpeg(
		filename="VennDiagram-DEG.jpeg",
		width=8,
		height=8,
		units="in",
		res=500)
	draw.triple.venn(
		area1=length(set1),
		area2=length(set2),
		area3=length(set3),
		n12=length(intersect(set1, set2)),
		n23=length(intersect(set2, set3)),
		n13=length(intersect(set1, set3)),
		n123=length(intersect(set1, intersect(set2, set3))),
		category=c("edgeR", "Limma-voom", "DESeq2"),
		fill = c("blue", "red", "green"))
	dev.off()
	}

suppressMessages(library("ggplot2"))
suppressMessages(library("ggrepel"))

inputdata <- sanityCheck()
suppressMessages(library("BiocParallel"))
suppressMessages(library("DESeq2"))
suppressMessages(library("edgeR"))
suppressMessages(library("limma"))
suppressMessages(library("annotables"))
suppressMessages(library("pheatmap"))
suppressMessages(library("RColorBrewer"))
suppressMessages(library("dplyr"))
suppressMessages(library("genefilter"))
suppressMessages(library("VennDiagram"))

DEG_edger <- proc_edger(inputdata)
DEG_limma <- proc_limma_voom(inputdata)
DEG_deseq <- proc_deseq2(inputdata)
makeVennDiagram(DEG_edger, DEG_limma, DEG_deseq)
cat("\n\nFinished!\n\n")