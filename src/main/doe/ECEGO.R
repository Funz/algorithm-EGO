#title: ECEGO
#help: Efficient Global Optimization (EGO) algorithm with equality constraints.
#tags: optimization; sparse; constraints
#author: yann.richet@irsn.fr; DiceKriging authors
#require: DiceDesign; DiceKriging; DiceView; pso; jsonlite
#options: initBatchSize='4'; batchSize='4'; iterations='10'; initBatchBounds='true'; trend='y~1'; covtype='matern3_2'; knots='0'; liar='upper95'; nugget='true'; trend_constr='y~1'; covtype_constr='matern3_2'; liar_constr='upper95'; nugget_constr='true';  seed='1'
#options.help: initBatchSize=Initial batch size; batchSize=iterations batch size; iterations=number of iterations; initBatchBounds=add input variables bounding values (2^d combinations); trend=(Universal) kriging trend; covtype=Kriging covariance kernel; knots=number of non-stationary points for each Xi; liar=liar value for in-batch loop (when batchsize>1); seed=random seed
#input: x=list(min=0,max=1)
#output: y=0.99

ECEGO <- function(options) {

  library(DiceDesign)
  library(DiceKriging)
  library(DiceView)
  library(pso)
  library(jsonlite)
  library(doParallel)
  if (!foreach::getDoParRegistered()) foreach::registerDoSEQ()

  ego = new.env()
  ego$i = 0

  ego$initBatchSize <- as.integer(options$initBatchSize)
  ego$batchSize <- as.integer(options$batchSize)
  ego$iterations <- as.integer(options$iterations)
  ego$initBatchBounds <- as.logical(options$initBatchBounds)
  ego$trend <- as.formula(options$trend)
  ego$covtype <- as.character(options$covtype)
  ego$liar <- as.character(options$liar)
  ego$knots <- as.integer(unlist(strsplit(as.character(options$knots),",")))
  ego$nuggetestim <- isTRUE(as.logical(options$nugget))
  if (ego$nuggetestim) {
    ego$nugget <- NULL
  } else {
    ego$nugget <- as.numeric(options$nugget)
    if (!is.numeric(ego$nugget) | is.na(ego$nugget)) ego$nugget = NULL
  }

  ego$trend_constr <- as.formula(options$trend_constr)
  ego$covtype_constr <- as.character(options$covtype_constr)
  ego$liar_constr <- as.character(options$liar_constr)
  ego$nuggetestim_constr <- isTRUE(as.logical(options$nugget_constr))
  if (ego$nuggetestim_constr) {
    ego$nugget_constr <- NULL
  } else {
    ego$nugget_constr <- as.numeric(options$nugget_constr)
    if (!is.numeric(ego$nugget_constr) | is.na(ego$nugget_constr)) ego$nugget_constr = NULL
  }


  ego$seed <- as.integer(options$seed)

  return(ego)
}

getInitialDesign <- function(algorithm, input, output) {
  algorithm$input <- input
  algorithm$output <- output

  d = length(input)
  if (!is.numeric(algorithm$initBatchSize))
    algorithm$initBatchSize = floor(eval(parse(text = algorithm$initBatchSize)))
  set.seed(algorithm$seed)

  d = length(input)
  lhs <- maximinESE_LHS(lhsDesign(n = algorithm$initBatchSize, dimension = d,seed=algorithm$seed)$design)$design
  if (isTRUE(algorithm$initBatchBounds)) {
    e = c(0, 1)
    id = 1
    while (id < d) {
      e = rbind(cbind(e, 0), cbind(e, 1))
      id = id + 1
    }
    Xinit = rbind(as.matrix(e), as.matrix(lhs))
  } else {
    Xinit = as.matrix(lhs)
  }

  for (i in 1:d)
    Xinit[,i] = Xinit[,i] * (input[[i]]$max-input[[i]]$min) + input[[i]]$min
  colnames(Xinit) <- names(input)

  return(Xinit)
}

getNextDesign <- function(algorithm, X, Y) {
  if (algorithm$i >= algorithm$iterations) return()

  set.seed(algorithm$seed)

  d = dim(X)[2]
  if (dim(Y)[2] > 2) {
    algorithm$noise.var <- as.array(Y[,2])^2
    y_constr = Y[,3]
    algorithm$nuggetestim = FALSE
    algorithm$nugget = NULL
  } else {
    algorithm$noise.var <- NULL
    y_constr = matrix(Y[,2],ncol=1)
  }

  y = Y[,1,drop=FALSE]

  # heuristic for lower bound of theta : max(1e-6, 0.1 * dX[which.max(dy/rowSums(dX))])
  dX = apply(FUN = dist, X, MARGIN = 2)
  dy = apply(FUN = dist, y, MARGIN = 2)
  dy_constr = apply(FUN = dist, y_constr, MARGIN = 2)

  # define stantionary-changing points
  all_knots <- generate_knots(knots.number = algorithm$knots, d = d, lower = sapply(algorithm$input, "[[", "min"), upper = sapply(algorithm$input, "[[", "max"))

  model <- NULL
  if (isTRUE(algorithm$knots>1))
    try(model <- km(algorithm$trend, optim.method = "BFGS",
                    covtype = algorithm$covtype,
                    design = X, response = y, noise.var = algorithm$noise.var,
                    lower = rep(pmax(1e-06, dX[which.max(dy/rowSums(dX)),]),each=algorithm$knots),
                    control = list(trace = FALSE),
                    nugget.estim = algorithm$nuggetestim,nugget = algorithm$nugget,
                    scaling = TRUE, knots = all_knots))
  else
    try(model <- km(algorithm$trend, optim.method = "BFGS",
                    covtype = algorithm$covtype,
                    design = X, response = y, noise.var = algorithm$noise.var,
                    lower = pmax(1e-06, dX[which.max(dy/rowSums(dX)),]),
                    control = list(trace = FALSE),
                    nugget.estim = algorithm$nuggetestim,nugget = algorithm$nugget,
                    scaling = FALSE, knots = NULL))

  if (is.null(model)) return() else algorithm$model <- model

  if (isTRUE(algorithm$knots>1))
    try(model_constr <- km(algorithm$trend_constr, optim.method = "BFGS",
                           covtype = algorithm$covtype_constr,
                           design = X, response = y_constr,
                           lower = rep(pmax(1e-06, dX[which.max(dy_constr/rowSums(dX)),]),each=algorithm$knots),
                           control = list(trace = FALSE),
                           nugget.estim = algorithm$nuggetestim_constr,nugget = algorithm$nugget_constr,
                           scaling = TRUE, knots = all_knots))
  else
    try(model_constr <- km(algorithm$trend_constr, optim.method = "BFGS",
                    covtype = algorithm$covtype_constr,
                    design = X, response = y_constr,
                    lower = pmax(1e-06, dX[which.max(dy_constr/rowSums(dX)),]),
                    control = list(trace = FALSE),
                    nugget.estim = algorithm$nuggetestim_constr,nugget = algorithm$nugget_constr,
                    scaling = FALSE, knots = NULL))

  if (is.null(model_constr)) return() else algorithm$model_constr <- model_constr

  lower = sapply(algorithm$input, "[[", "min")
  upper = sapply(algorithm$input, "[[", "max")

  oEGO <- max_qEITSEE(model = algorithm$model, model.constr=algorithm$model_constr, npoints = algorithm$batchSize,
                      L = algorithm$liar,L.constr = algorithm$liar_constr,
                      lower=lower,upper=upper,
                      control = list(trace = FALSE, init = algorithm$i==0))

  if (is.null(oEGO))
    return()

  Xnext <- oEGO$par
  algorithm$i <- algorithm$i + 1

  Xnext = as.matrix(Xnext)
  colnames(Xnext) <- names(algorithm$input)
  return(Xnext)
}

displayResults <- function(algorithm, X, Y) {
  algorithm$files <- paste("ECEGO_view_", algorithm$i,".png", sep = "")
  resolution <- 600

  if (dim(Y)[2] > 2) {
    noise.var <- as.array(Y[,2])^2 
    yname = paste0("N(", colnames(Y)[1], ",", colnames(Y)[2],")")
    y_constr = Y[,3]
    y_constrname = colnames(Y)[3]
  } else {
    noise.var <- NULL
    yname = colnames(Y)[1]
    y_constr = matrix(Y[,2],ncol=1)
    y_constrname = colnames(Y)[2]
  }
  y = Y[, 1]

  yy = y * abs(y_constr)
  m.ix = which(yy == min(yy))
  m = y[m.ix]
  x = as.matrix(X)[m.ix, ]
  html = paste0("<HTML>minimum is ", yname," = ",format(y[m.ix],digits=6),
                " for ",y_constrname," = ",format(y_constr[m.ix],digits=6),"<br/>",
                " found at <br/>",
                paste0(collapse = "<br/>",paste(sep = "= ", colnames(X), format(x,digits=3))),
                "<br/><img src='", algorithm$files,
                "' width='", resolution, "' height='", resolution, "'/></HTML>")
  html = paste0(html,"<min>",m,"</min><argmin>",toJSON(x),"</argmin>")

  if (is.null(algorithm$model)) {
    png(file = algorithm$files, bg = "transparent", height = resolution, width = resolution)
    try(pairs(cbind(X,Y)))
    dev.off()
    return(html)
  }

  png(file = algorithm$files, bg = "transparent", height = resolution, width = resolution)
  try(sectionview(algorithm$model, center = x, Xname = colnames(X), yname = yname))
  #try(sectionview(function(x)m,col_surf = 'red',add=T))
  dev.off()

  #if (algorithm$i == algorithm$iterations) {
  html = paste0(html,"<data_json>",toJSON(as.data.frame(cbind(X,Y)),dataframe = "columns"),"</data_json>")

  lower = sapply(algorithm$input, "[[", "min")
  upper = sapply(algorithm$input, "[[", "max")
  n = 1000
  set.seed(123) # to get the same points for evaluating model
  Xm = matrix(lower,nrow=n,ncol=length(lower),byrow = T) + matrix(upper-lower,nrow=n,ncol=length(lower),byrow = T) * matrix(runif(n*length(lower)),nrow=n,ncol=length(lower))
  colnames(Xm) <- colnames(X)
  Ym = list(mean=rep(NA,n),sd=rep(NA,n))
  try(Ym <- predict(algorithm$model,newdata = Xm,type = "UK",cov.compute = F, low.memory = T,checkNames=F))
  Ym = cbind(Ym$mean,Ym$sd)
  colnames(Ym) <- c(colnames(Y),paste0("sd_",colnames(Y)))[1:2]

  html = paste0(html,"<model_json>",toJSON(as.data.frame(cbind(Xm,Ym)),dataframe = "columns"),"</model_json>")

  html = paste0(html,"<kriging_json>",toJSON(algorithm$model,force=TRUE,auto_unbox=TRUE,pretty=TRUE,dataframe = "columns"),"</kriging_json>")
  #}

  return(paste0(html,collapse=';'))
}

displayResultsTmp <- displayResults

################### Algorithm dependencies ###################

#' @test optims(pars=t(t(seq(-20,20,,20))),fn=function(x) ifelse(x==0,1,sin(x)/x),lower=-20,upper=20,method='L-BFGS-B')
#' @test f = function (x) { x1 <- x[1] * 15 - 5;x2 <- x[2] * 15;(x2 - 5/(4 * pi^2) * (x1^2) + 5/pi * x1 - 6)^2 + 10 * (1 - 1/(8 * pi)) * cos(x1) + 10;}; optims(pars=matrix(runif(100),ncol=2),f,method="L-BFGS-B",lower=c(0,0),upper=c(1,1))
# import("doParallel")
optims <- function(pars,fn,fn.NaN=NaN,...) {
  fn.o = function(...) {
    y = fn(...)
    if (is.nan(y))
      return(fn.NaN)
    else
      return(y)
  }
  O = foreach(i.o = 1:nrow(pars),.errorhandling = "remove") %dopar% {
    return(optim(par=pars[i.o,],fn=fn.o,...))
  }
  best = list(par=NA,value=NA)
  all = NULL
  norm = apply(pars,2,function(x) diff(range(x)))
  for (o in O) {
    if (!isTRUE(best$value < o$value))
      best = o
    if (is.null(all))
      all = list(pars=matrix(o$par,nrow=1),values=matrix(o$value,nrow=1))
    else if (min_dist(o$par,all$pars)>1E-3) {
      all$pars=rbind(all$pars,o$par)
      all$values=rbind(all$values,o$value)
    }
  }
  c(best,all)
}

generate_knots <- function(knots.number=NULL,d,lower=NULL,upper=NULL){

  if(is.null(lower)) lower <- rep(0,times=d)
  if(is.null(upper)) upper <- rep(1,times=d)

  if(is.null(knots.number)) return(NULL)

  if (length(knots.number) == 1) {
    if (knots.number > 1) {
      knots.number <- rep(knots.number, times = d)
    } else {
      return(NULL)
    }
  }

  if (length(knots.number) != d) {
    print("Error in function generate_knots. The size of the vector knots.number needs to be equal to d")
    return(NULL)
  }

  knots.number <- pmax(1,knots.number) # 2 knots at least per dimension

  thelist <- list()
  for (i in 1:d) {
    thelist[[i]] <- seq(from = lower[i], to = upper[i], length = knots.number[i])
  }
  return(thelist)
}


#' @test X=matrix(runif(10),ncol=1); y=-sin(pi*X); kmi <- km(design=X,response=y); EI(runif(100),kmi)
#' @test X=matrix(runif(10),ncol=1); y=-sin(pi*X); kmi <- km(design=X,response=y); DiceView::sectionview(kmi,dim=1); DiceView::sectionview(function(x)EI(x,kmi),dim=1);
#' @test X=matrix(c(0,.25,.75,1),ncol=1); y=-sin(pi*X); kmi <- km(design=X,response=y,lower=0.1); DiceView::sectionview(kmi); DiceView::sectionview(function(x)EI(x,kmi),dim=1);
#' @test X=matrix(c(0,.25,.75,1),ncol=1); y=sin(pi*X); kmi <- km(design=X,response=y,noise.var=rep(0.1,4)^2,lower=0.1); DiceView::sectionview(kmi); DiceView::sectionview(function(x)EI(x,kmi),dim=1);
#' @test X=matrix(c(0,.25,.75,1),ncol=1); y=-sin(pi*X); kmi <- km(design=X,response=y,noise.var=rep(0.1,4)^2,lower=0.1); DiceView::sectionview(kmi); DiceView::sectionview(function(x)EI(x,kmi),dim=1);
#' @test X=matrix(c(0,.25,.75,1,.25,.25,.25),ncol=1); y=-sin(pi*X); kmi <- km(design=X,response=y,noise.var=rep(0.25,nrow(X))^2,lower=0.1); DiceView::sectionview(kmi); DiceView::sectionview(function(x)EI(x,kmi),dim=1);
#' @test X=matrix(runif(20),ncol=2); y=apply(X,1,branin); kmi <- km(design=X,response=y); DiceView::contourview(function(x)EI(x,kmi),dim=2); points(X)
#' @test X=matrix(runif(20),ncol=2); y=-apply(X,1,branin); kmi <- km(design=X,response=y); DiceView::contourview(function(x)EI(x,kmi),dim=2); points(X)
EI <- function (x, model, plugin = NULL){
  # Check for x, restrict to model input bounds
  if (any(is.na(x))) {print(x);stop(paste0("x has NA:",paste0(x,collapse=",")))}
  if (any(is.null(x))) {print(x);stop(paste0("x has NULL:",paste0(x,collapse=",")))}
  if (!is.matrix(x))
    x <- matrix(x, ncol = model@d)
  lower = apply(model@X, 2, min)
  upper = apply(model@X, 2, max)
  for (i in 1:model@d) {
    x[,i] = pmax(x[,i],lower[i])
    x[,i] = pmin(x[,i],upper[i])
  }
  colnames(x) = colnames(model@X)
  d <- ncol(x)
  if (is.null(plugin)) {
    if (model@noise.flag) {
      #plugin <- min(model@y + 2 * sqrt(model@noise.var)) # upper95 plugin
      # Because predict of noised points should ot always return kriging mean:
      plugin <- min(predict.km(model,model@X,"UK",light.return = T,bias.correct = F,se.compute = F)$mean)
    } else
      plugin <- min(model@y)
  }
  m <- plugin
  if (d != model@d)
    stop("x does not have the right number of columns (", d, " instead of ", model@d, ")")

  newdata <- x
  colnames(newdata) = colnames(model@X)
  predx <- predict.km(object = model, newdata = newdata, type = "UK", checkNames = TRUE)
  kriging.mean <- predx$mean
  kriging.sd <- predx$sd
  xcr <- (m - kriging.mean)/kriging.sd
  xcr.prob <- pnorm(xcr)
  xcr.dens <- dnorm(xcr)
  res <- (m - kriging.mean) * xcr.prob + kriging.sd * xcr.dens
  too.close = which(kriging.sd/sqrt(model@covariance@sd2) < 1e-06)
  res[too.close] <- max(0, m - kriging.mean)
  return(res)
}

#' @test X=matrix(runif(10),ncol=1); y=-sin(2*pi*X); kmi <- km(design=X,response=y); TSEE(runif(100),kmi)
#' @test X=matrix(runif(10),ncol=1); y=-sin(2*pi*X); kmi <- km(design=X,response=y); DiceView::sectionview.fun(function(x)TSEE(x,kmi),dim=1)
#' @test X=matrix(runif(10),ncol=2); y=branin(X); kmi <- km(design=X,response=y); DiceView::contourview.fun(function(x)TSEE(x,kmi),dim=2)
#' @require KrigInv
TSEE = function (x, model, T=0) {
  if (!is.matrix(x)) x <- matrix(x,ncol= model@d)
  y <- t(x)
  if ((nrow(y) == 1) && (ncol(y) == model@d)) {
    z <- y
  }
  else {
    if (ncol(x) == model@d)
      z <- x
    if (ncol(x) != model@d)
      z <- y
  }
  newdata <- x
  colnames(newdata) = colnames(model@X)
  krig <- predict.km(object = model, newdata = newdata, type = "UK", se.compute = TRUE)
  mk <- krig$mean
  sk <- krig$sd
  t <- (T - mk)/sk
  ski_dnorm_t <- sk * dnorm(t)
  C <- ((T - mk) * pnorm(t) + ski_dnorm_t) * ((mk - T) * pnorm(-t) + ski_dnorm_t)
  C[is.nan(C)] <- 0
  return(C)
}

#' @test X=matrix(runif(20),ncol=2); y=branin(X); kmi <- km(design=X,response=y); y.constr = rowSums(X)-1; kmi.constr=km(design=X,response=y.constr); DiceView::contourview.fun(function(x)EITSEE(x,kmi,kmi.constr),dim=2)
EITSEE = function(x,model, model.constr){
  return(EI(x,model)*TSEE(x,model.constr))
}

#' @test set.seed(1); X=matrix(runif(20),ncol=2); y=branin(X); kmi <- km(design=X,response=y); y.constr = rowSums(X)-1; kmi.constr=km(design=X,response=y.constr); DiceView::contourview.fun(function(x)EITSEE(x,kmi,kmi.constr),dim=2); points(max_EITSEE(kmi,kmi.constr,lower=c(0,0),upper=c(1,1))$par)
max_EITSEE <-function(model, model.constr, lower, upper, control=NULL) {
  d <- ncol(model@X)
  # if (is.null(control$print.level))
  #   control$print.level <- 1
  # if (is.null(control$max.parinit.iter))
  #   control$max.parinit.iter <- 10^d
  # if (d <= 6)
  #   N <- 10 * 2^d
  # else
  #   N <- 100 * d
  # if (is.null(control$pop.size))
  #   control$pop.size <- N
  # if (is.null(control$solution.tolerance))
  #   control$solution.tolerance <- 1e-15

  #pars = NULL
  #for (i in 1:d) pars = cbind(pars, matrix(runif(control$pop.size, lower[i], upper[i]), ncol = 1))
  mesh <- geometry::delaunayn(model@X)
  pars <- #rbind(pars,
    as.matrix(apply(mesh,1,function(t)colMeans(model@X[t,,drop=FALSE]))) #)
  if (ncol(pars)!=ncol(model@X)) pars = t(pars)
  ei <- EITSEE(pars, model, model.constr)
  good_start <- which(ei > 0.1*max(ei, na.rm = T))
  par0 <- pars[good_start,,drop=FALSE] #matrix(pars[good_start[sample(1:length(good_start), 1)], ], nrow = 1)
  o <- optims(par0,function(x) -EITSEE(x, model, model.constr),
              method = "L-BFGS-B",lower = lower, upper=upper)
  for (i in 1:d) {
    o$par[i] = max(o$par[i],lower[i])
    o$par[i] = min(o$par[i],upper[i])
  }

  return(list(par=matrix(o$par,ncol=d),value=-o$value))
}


#' @test set.seed(1); X=matrix(runif(20),ncol=2); y=branin(X); kmi <- km(design=X,response=y); y.constr = rowSums(X)-1; kmi.constr=km(design=X,response=y.constr); DiceView::contourview.fun(function(x)EITSEE(x,kmi,kmi.constr),dim=2); points(max_qEITSEE(kmi,kmi.constr,npoints=5,L="upper95",L.constr="upper95",lower=c(0,0),upper=c(1,1))$par)
max_qEITSEE <- function(npoints, model, model.constr, lower, upper, L, L.constr,  control=NULL, ...) {
  n1 <- nrow(model@X)
  for (s in 1:npoints) {
    oEGO <- max_EITSEE(model=model, model.constr=model.constr, lower=lower, upper=upper, control, ...)
    if (!model@noise.flag)
      if (min_dist(oEGO$par, model@X) <= prod(upper - lower) * 1e-10) { # no more retry
        warning("Proposed a point already in design. So aborting batch to size ",s-1)
        npoints = s - 1
        break
      }

    if (L=="min")
      l = min(model@y)
    else if (L=="max")
      l = max(model@y)
    else if (L=="upper95")
      l = predict.km(object = model, newdata = oEGO$par,
                     type = "UK", light.return = TRUE)$upper95
    else if (L=="lower95")
      l = predict.km(object = model, newdata = oEGO$par,
                     type = "UK", light.return = TRUE)$lower95
    else l = L

    model@X <- rbind(model@X, oEGO$par)
    model@y <- rbind(model@y, l, deparse.level=0)
    model@F <- trendMatrix.update(model, Xnew=data.frame(oEGO$par))
    if (model@noise.flag) {
      model@noise.var = c(model@noise.var, 0)
    }
    newmodel = NULL
    try(newmodel <- computeAuxVariables(model))
    if (is.null(newmodel)) {
      warning("Failed to update model !")
      npoints = s - 1
      break
    } else
      model = newmodel

    if (L.constr=="min")
      l.constr = min(model.constr@y)
    else if (L.constr=="max")
      l.constr = max(model.constr@y)
    else if (L.constr=="upper95")
      l.constr = predict.km(object = model.constr,newdata = oEGO$par,type="UK",light.return = TRUE)$upper95
    else if (L.constr=="lower95")
      l.constr = predict.km(object = model.constr,newdata = oEGO$par,type="UK",light.return = TRUE)$lower95
    else l.constr = L.constr

    model.constr@X <- rbind(model.constr@X, oEGO$par)
    model.constr@y <- rbind(model.constr@y, l.constr, deparse.level=0)
    model.constr@F <- trendMatrix.update(model.constr, Xnew=data.frame(oEGO$par))
    if (model.constr@noise.flag) {
      model.constr@noise.var = c(model.constr@noise.var, 0)
    }
    newmodel.constr = NULL
    try(newmodel.constr <- computeAuxVariables(model.constr))
    if (is.null(newmodel.constr)) {
      warning("Unable to update model.constr !")
      npoints=s-1
      break
    } else
      model.constr = newmodel.constr

  }

  if (npoints == 0)
    return()
  return(list(par = model@X[(n1 + 1):(n1 + npoints), , drop = FALSE],
              value = model@y[(n1 + 1):(n1 + npoints), , drop = FALSE]))
}

########################################## EXAMPLE ##############################################
# f <- function(X) matrix(apply(X,1,function (x) {
#   x1 <- x[1]*15-5
#   x2 <- x[2]*15
#   y = matrix((x2 - 5/(4*pi^2)*(x1^2) + 5/pi*x1 - 6)^2 + 10*(1 - 1/(8*pi))*cos(x1) + 10,ncol=1)
#   y_constr = (x[1] - 0.5427730) * (x[2] - 0.15)
#   cbind(y,y_constr)
# }),ncol=2)
# 
# options = list(initBatchSize='8', batchSize='8', iterations='10', initBatchBounds='true', trend='y~1', covtype='matern3_2', knots='2', liar='upper95', nugget='0.1', seed='1', trend_constr='y~1', covtype_constr='matern3_2', nugget_constr='0.1', liar_constr='upper95' )
# algorithm = ECEGO(options)
# 
# X0 = getInitialDesign(algorithm, input=list(x1=list(min=0,max=1),x2=list(min=0,max=1)), NULL)
# Y0 = f(X0)
# # X0 = getInitialDesign(gd, input=list(x2=list(min=0,max=1)), NULL)
# # Y0 = f1(X0)
# Xi = X0
# Yi = Y0
# 
# finished = FALSE
# while (!finished) {
#   print(displayResultsTmp(algorithm,Xi,Yi))
#   Xj = getNextDesign(algorithm,Xi,Yi)
#   if (is.null(Xj) | length(Xj) == 0) {
#     finished = TRUE
#   } else {
#     Yj = f(Xj)
#     Xi = rbind(Xi,Xj)
#     Yi = rbind(Yi,Yj)
#   }
# }
# 
# print(displayResults(algorithm,Xi,Yi))
