.rhat<-function(...){
	#confirm all elements are the same length
	cond<-diff(range(as.vector(unlist(Map(length,list(...))))))==0
	if(!cond)
	{
		stop("Not all arugments are of equal length")
	}
	#rank normalization according to eq 14 of arxiv: 1903.08008.pdf
	.ranknorm<-function(...){
		(matrix(rank(do.call(cbind,list(...))),ncol=length(list(...)))-3/4)/(length(list(...)[[1]])-1/4)
	}

	phimn<-.ranknorm(...)

	# mean of each chain
	.phiM <- function(phimn){
		colMeans(phimn)
	}

	#mean across chains
	.phi <- function(phim){
		mean(phim)
	}

	PHIM<-.phiM(phimn)
	PHI<-.phi(PHIM)

	#between chain variance
	.B <- function(PHI,PHIM,PHIMN){
		sum((PHIM-PHI)^2)*nrow(PHIMN)/(ncol(PHIMN)-1)
	}

	between<-.B(PHI,PHIM,phimn)
	# s_squared
	.ssq<-function(PHIMN,PHIM){
		colSums((t(t(PHIMN)-PHIM))^2)/(nrow(PHIMN)-1)
	}

	s2<-.ssq(phimn,PHIM)
	within<-mean(s2)
	#Rhat
	sqrt((((nrow(phimn)-1)/nrow(phimn))*within+(1/nrow(phimn))*between)/within)

}


#' Check the convergence of multiple COMPASS models fit with different seeds.
#'
#' Computes Rhat for all nsubjects x nsubsets parameters across the list of models, treated as separate chains.
#' Flags cell populations and subjects with Rhat > 1.01. 
#' The most frequently flagged population is passed for further diagnostis to compute Rhat between all pairs of models and
#' to try and identify the model or models that are outliers.
#' The outliers are removed and a list of good models is returned.
#' @note Uses foreach and doMC, so it won't work on windows.
#' 
#' @param mlist A list of COMPASSResult models. Each should be fit to the same data, but with different seeds.
#' @param ncores The number of cores to use, if supported on the system.
#' @return A list of COMPASSResult models that are consistent / have converged. 
#' @export
#' @importFrom utils txtProgressBar setTxtProgressBar
#' @import foreach
#' @import coda
#' @examples
#' data(COMPASS)
#' set.seed(100)
#' fit <- COMPASS(CC,
#'   category_filter=NULL,
#'   treatment=trt == "Treatment",
#'   control=trt == "Control",
#'   verbose=FALSE,
#'   iterations=100 ## set higher for a real analysis
#' )
#' set.seed(200)
#' fit2 <- COMPASS(CC,
#'   category_filter=NULL,
#'   treatment=trt == "Treatment",
#'   control=trt == "Control",
#'   verbose=FALSE,
#'   iterations=100 ## set higher for a real analysis
#' )
#' checkCOMPASSConvergence(list(fit,fit2))
checkCOMPASSConvergence<-function(mlist,ncores=1){
  if(!is.list(mlist)){
    stop("mlist should be a list of COMPASSResult fit to the same data with different random seeds.")
  }
  allok<-TRUE
 if(!requireNamespace("foreach",quietly=TRUE)){
	  message("foreach is required to run checkCOMPASSConvergence")
	  allok<-FALSE
  }
  if(requireNamespace("doMC",quietly=TRUE)&allok){
  	doMC::registerDoMC(ncores)
  }else{
	message("You may want to install the doMC package")
  }
 if(!requireNamespace("progress",quietly=TRUE)){
	  message("progress is required to run checkCOMPASSConvergence")
	  allok<-FALSE
  }
  if(allok){
  
  if(length(mlist)<2){
    stop("mlist must be a list of > 2 COMPASS Results fit to the same data.")
  }
  for(i in 2:length(mlist)){
    if(!all.equal(mlist[[1]]$data,mlist[[i]]$data)){
      stop("Input models are not all fit to the same data. Stopping,")
    }
  }
  # List of models is compatible.
  # Extract the gamma matrices
  gammas<-Map(function(x)x$fit$gamma,mlist)
  #How many subjects and cell subsets
  nsamples<-dim(gammas[[1]])[1]
  nsubsets<-dim(gammas[[1]])[2]
  message(paste0("Checking convergence of ",nsamples*nsubsets, " parameters"))
  rhat_matrix_all<-matrix(0,nrow=nsamples,ncol=nsubsets)
  pb<-txtProgressBar(min=0,max=1,style=3,title = "Checking convergence...")
  suppressWarnings({
  rhat_matrix_all<-foreach(i = 1:nsamples,.combine = rbind,.errorhandling = "remove") %dopar% {
    setTxtProgressBar(pb,max(pb$getVal(),i/nsamples))
     result<-rep(0,nsubsets)
    for(j in 1:nsubsets){
      result[j]<-do.call(.rhat,Map(function(x)x[i,j,],gammas))
    }
     result
   }})
   
   ranked_problematic_subsets<-sort(table(which(rhat_matrix_all>1.01,T)[,2]),decreasing=TRUE)
   message(paste0("\nDetected convergence issues in ",length(ranked_problematic_subsets)," cell subsets"))
   message("Running further diagnostics to identify outlier chains..")
   top_problem_subset<-as.numeric(names(ranked_problematic_subsets)[1])
   subset_phenotype<-paste0(paste(names(which(mlist[[1]]$fit$categories[top_problem_subset,]==1)),collapse="+"),"+")
   subset_phenotype<-gsub("Counts\\+","",subset_phenotype)
   
   #pick a subject with poor convergence for this subset
   j<-as.numeric(gsub("result\\.","",names(which(which(rhat_matrix_all>1.01,T)[,2]==top_problem_subset)[1])))
   chains<-Map(function(x)x[j,top_problem_subset,],gammas)
   combinations<-combn(length(gammas),2)
   rhat_pair_matrix<-matrix(0,ncol=length(gammas),nrow=length(gammas))
   for(i in 1:ncol(combinations)){
     j<-combinations[,i][1]
     k<-combinations[,i][2]
     rhat_pair_matrix[j,k]<-.rhat(chains[[j]],chains[[k]])
   }
   rhat_pair_matrix[lower.tri(rhat_pair_matrix)]<-t(rhat_pair_matrix)[lower.tri(t(rhat_pair_matrix))]
   drop_ind<-sapply(1:length(gammas), function(i) {
     if (all(rhat_pair_matrix[, i][-i] > 1.01)) {
       message(paste0("Dropping model ",i))
       i
     }
   })
   drop_ind<-unlist(Filter(function(x)!is.null(x),drop_ind))
   mlist[-drop_ind]
  }
}

#'@title Diagnostic of a set of COMPASS Models.
#' @param x a list of compass model fits of the same data with the same number of iterations, different seeds.
#' Run some mcmc diagnostics on a series of COMPASS model fits.
#' Assuming the input is a list of model fits for the same data with the same number of iterations and different seeds.
#' Run Gelman's Rhat diagnostics on the alpha_s and alpha_u hyperparameter chains, treating each model as an independent chain.
#' Rhat should be near 1 but rarely are in practice. Very large values may be a concern.
#' The method returns an average model, by averaging the mean_gamma matrices (equally weighted since each input has the same number of iterations).
#' This mean model should be better then any of the individual models.
#' It can be plotted via "plot(result$mean_model)".
#' @importFrom stats fisher.test
#' @export
COMPASSMCMCDiagnosis<-function(x){
    diag<-list()
    diag$alpha_s<-coda::gelman.diag(Map(function(x)coda::as.mcmc(x$fit$alpha_s),x))
    diag$alpha_u<-coda::gelman.diag(Map(function(x)coda::as.mcmc(x$fit$alpha_u),x))
  mean_gamma <- apply(Map(function(x) abind(x, along = 3), Map(function(x) x$fit$mean_gamma, x))[[1]], 1:2, mean)
  mean_model <- x[[1]]
  mean_model$fit$mean_gamma <- mean_gamma
    return(list(diag=diag,mean_model=mean_model))
}
