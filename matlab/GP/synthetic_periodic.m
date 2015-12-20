%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% @author Xinyan
% @date Dec 20, 2015
% Modified from RangeISAMExample_plaza.m in the GTSAM 3.2 matlab toolbox
% GTSAM: https://collab.cc.gatech.edu/borg/gtsam/
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% Synthetic data format similar to the plaza data available at 
% data available at http://www.frc.ri.cmu.edu/projects/emergencyresponse/RangeData/
% Datafile format (from http://www.frc.ri.cmu.edu/projects/emergencyresponse/RangeData/log.html)
% GT: Groundtruth path from GPS
%    Time (sec)	X_pose (m)	Y_pose (m)	Heading (rad)
% DR: Odometry Input (delta distance traveled and delta heading change)
%    Time (sec)	Delta Dist. Trav. (m)	Delta Heading (rad)
% DRp: Dead Reckoned Path from Odometry
%    Time (sec)	X_pose (m)	Y_pose (m)	Heading (rad)
% TL: Surveyed Node Locations
%    Time (sec)	X_pose (m)	Y_pose (m)
% TD
%    Time (sec)	Sender / Antenna ID	Receiver Node ID	Range (m)

clear;
import gtsam.*
datafile = '../Data/Syn_theta_Plaza.mat';
incK= 10; % minimum number of range measurements to process after
avgRangeFreq = 1;
useRobust = true;
XL_ordering = false;
% XL_ordering = true;
extra_num_update_at_last = 0;
bufferedVelProj_size = 0;
to_interpolate = false;
% to_interpolate = true;
% to_visualize = false;
to_visualize = true;
visualI = 100;
periodic_script = true;

load(datafile)
M = size(DR,1);
K = size(TD,1);
headingOffset = 0;
addRange = true;

%% Set Noise parameters
dt = 1;
Qc = diag([1, 1, 25])*0.01;
noiseModels.velProj = noiseModel.Diagonal.Sigmas([0.5 0.5 1]');                 % velocity projected
noiseModels.velProjInterpolated = noiseModel.Diagonal.Sigmas([0.5 0.5 1]');     
noiseModels.prior = noiseModel.Diagonal.Sigmas([1 1 pi]');
noiseModels.pointPrior = noiseModel.Diagonal.Sigmas([1 1]');
sigmaR = 1;
if useRobust
    base = noiseModel.mEstimator.Tukey(15);
    noiseModels.range = noiseModel.Robust(base,noiseModel.Isotropic.Sigma(1, sigmaR));
else
    noiseModels.range = noiseModel.Isotropic.Sigma(1, sigmaR);
end


%% Add prior on first pose
pose0 = Pose2(GT(1,2),GT(1,3),headingOffset+GT(1,4));
pose0lv = LieVector([GT(1,2),GT(1,3),headingOffset+GT(1,4)]');
vel0 = LieVector([1e-4, 1e-4, 1e-4]');

newFactors = NonlinearFactorGraph;
newFactors.add(PriorFactorLieVector(symbol('P',0),pose0lv,noiseModels.prior));
newFactors.add(PriorFactorLieVector(symbol('V',0),vel0,noiseModels.prior));
initial = Values;
initial.insert(symbol('P',0),pose0lv);
initial.insert(symbol('V',0),vel0);

odo = Values;
odo.insert(symbol('P',0),pose0);

usefulRangeInd = zeros(size(TD,1), 1);
addedK = 0;     % the number of actually used range measurement so far

%% initialize points
seen_lmkey = zeros(size(TL,1), 1);
landmarkEstimates = Values;

% Only leave the range measurements at which we will have estimated states
ratio = bufferedVelProj_size + 1;
if (M ~= K-1)
    disp('Error in the number of states and range measurements in Synthetic dataset!');
    return;
end
% Add range measurement for trajectory state symbol('P',0)
factor = RangeFactorLVLieVectorPoint2(symbol('P',0), symbol('L',TD(1,3)), ...
    TD(1,4), noiseModels.range);
newFactors.add(factor); 
j = 1;
Lj = Point2(TL(j,2),TL(j,3));
initial.insert(symbol('L',j),Lj);
landmarkEstimates.insert(symbol('L',j),Lj);
newFactors.add(PriorFactorPoint2(symbol('L',j),Lj,noiseModels.pointPrior));
seen_lmkey(j) = 1;
allInds = 1:(K-1);
neededInds = allInds(  (mod(allInds, avgRangeFreq) < ratio) & (mod(allInds, ratio) == 0) ) + 1;
neededInds = [neededInds, 1500];
TD = TD(neededInds, :);
K = size(TD,1);

%% Loop over
step_t = zeros(M, 2);
ipv = 0;
k = 1;                  % current index in TD
lastPose = pose0;
lastUpdateVel = vel0;
lastPoselv = pose0lv;
odoPose = pose0;
countK = 0;

lastEstStateInd = 0;
bufferedVelProj = cell(bufferedVelProj_size,1);
estStateInds = zeros(M+1,1);
nEstStateInds = 1;

for i=1:M 
    tic;
    addEstState = false;
    % Add odometry measurement
    t = DR(i,1);
    distance_traveled = DR(i,2);
    delta_heading = DR(i,3);
    odometry = Pose2(distance_traveled,0,delta_heading);
    
    % Predict pose and update odometry
    predictedOdo = odoPose.compose(odometry);
    odoPose = predictedOdo;
    odo.insert(symbol('P',i),predictedOdo);
    
    % Predict pose and add as initial estimate
    predictedPose = lastPose.compose(odometry);
    pmv = lastPoselv.vector();
    predictedPoselv = LieVector([predictedPose.x(); predictedPose.y(); pmv(3)+delta_heading]);
    lastPoselv = predictedPoselv;
    velProj = LieVector([distance_traveled/dt, 0, delta_heading/dt]');
    deltaX = predictedPose.x() - lastPose.x();
    deltaY = predictedPose.y() - lastPose.y();
    deltaTheta = predictedPose.theta() - lastPose.theta();
    predictedVel = LieVector( [deltaX / dt, deltaY / dt, deltaTheta / dt]');
    lastPose = predictedPose;
    
    % Check if there are range factors to be added
    while k<=K && t>=TD(k,1)
        j = TD(k,3);
        range = TD(k,4);
        if addRange
            % Newly seen landmark
            if ~seen_lmkey(j)
                Lj = Point2(TL(j,2),TL(j,3));
                newFactors.add(PriorFactorPoint2(symbol('L',j),Lj,noiseModels.pointPrior));
                initial.insert(symbol('L',j),Lj);
                landmarkEstimates.insert(symbol('L',j),Lj);
                seen_lmkey(j) = 1;
            end
            
            factor = RangeFactorLVLieVectorPoint2(symbol('P',i), symbol('L',j), ...
                range, noiseModels.range);
            % Throw out obvious outliers based on current landmark estimates
            if ~landmarkEstimates.exists(symbol('P',i))
                landmarkEstimates.insert(symbol('P',i),predictedPoselv);
            end
            error=factor.unwhitenedError(landmarkEstimates);
            newFactors.add(factor);
            addedRange = true;
        end
        if (addedRange)
            countK =countK+1;
            addEstState = true;
            addedK = addedK + 1;
            usefulRangeInd(addedK) = k;
        end
        k=k+1;          % increase the TD index
    end
    
    if (addEstState) || ((i-lastEstStateInd) > bufferedVelProj_size)
        initial.insert(symbol('P',i),predictedPoselv);
        initial.insert(symbol('V',i),predictedVel);
        newFactors.add(VFactorLieVector(symbol('P', i), symbol('V', i), velProj, ...
            noiseModels.velProj));
        delta_t = i - lastEstStateInd;
        Qi = calc_Q(Qc, delta_t);
        noiseModels.gp = noiseModel.Gaussian.Covariance(Qi);
        newFactors.add(GaussianProcessPriorPose2LieVector(symbol('P', lastEstStateInd), symbol('V', lastEstStateInd), ...
            symbol('P', i), symbol('V', i), delta_t, noiseModels.gp));  
        % Add interpolated velProj factors
        for kkk = lastEstStateInd + 1: i - 1
            tao = kkk - lastEstStateInd;
            velProj = bufferedVelProj{tao};
            if (to_interpolate)
                newFactors.add(InterpolatedVFactorLieVector( ...
                    symbol('P',lastEstStateInd), symbol('V',lastEstStateInd), symbol('P',i), symbol('V',i), ...
                    delta_t, tao, velProj, noiseModels.velProjInterpolated));
            end
        end
        lastEstStateInd = i;                % updaet lastEstStateInd
        nEstStateInds = nEstStateInds + 1; 
        estStateInds(nEstStateInds) = i;    % record i
    else
        bufferedVelProj{i-lastEstStateInd} = velProj;
    end
    
    % Check whether to update
    if countK>=incK && addEstState
        % Prepare ordering, stop timer
        step_t(i, 1) = step_t(i, 1) + toc;
        param = LevenbergMarquardtParams();
        if (XL_ordering)
            ordering = Ordering();
            % XL ordering
            sz = nEstStateInds;
            % Push trajectory state variables
            for ii=1:sz
                ordering.push_back(symbol('P', estStateInds(ii)));
                ordering.push_back(symbol('V', estStateInds(ii)));
            end
            % Push landmark variables
            ind = find(seen_lmkey);
            for ii = 1:size(ind,1)
                ordering.push_back(symbol('L', ind(ii)));
            end
        else
            ordering = newFactors.orderingCOLAMD();
        end
        param.setOrdering(ordering);
        tic;
        
        optimizer = LevenbergMarquardtOptimizer(newFactors, initial, param);
        optimizer.iterate();        
        initial = optimizer.values();             
        
        result = initial; 
        lastPoselv = result.at(symbol('P',i));
        lastPose = lastPoselv.vector();   % update last pose
        lastPose = Pose2(lastPose(1), lastPose(2), lastPose(3));
        lastUpdateVel = result.at(symbol('V',i));
        step_t(i, 1) = step_t(i, 1) + toc; % stop clock
        
        % Update landmark estimates
        if addRange
            landmarkEstimates = Values;
            ind = find(seen_lmkey);
            for ii = 1:size(ind,1)
                key = symbol('L',ind(ii));
                landmarkEstimates.insert(key,result.at(key));
            end
        end
        countK = 0;
        
        % Visualize
        if i - ipv >= visualI && to_visualize
            ipv = i;
            figure(1);clf;hold on
            result = initial;
            loop_plot;
        end
        tic;
    end

    step_t(i, 1) = step_t(i, 1) + toc;
    if (i == 1)
        step_t(i, 2) = step_t(i, 1);
    else
        step_t(i, 2) = step_t(i, 1) + step_t(i-1, 2);
    end
    
end

toc

%% Plot ground truth as well
plot(GT(:,2),GT(:,3),'g-');
plot(TL(:,2),TL(:,3),'g*');


%% Plot final result
figure; hold on;
estStateInds = estStateInds(1:nEstStateInds);
result = initial;
final_plot;



