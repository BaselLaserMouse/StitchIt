function stitchSection(section, channel, varargin)
% Stitch one or more sections of data from one channel
%
% function stitchSection(section, channel, 'param', 'val', ... )
%
% Purpose
% This function loads data to be stitched, pre-processes them as needed
% using previously saved parameters (comb correction, photobleach correction, 
% intensity correction, tile registration, etc). Stitching parameters that will
% remain fairly constant, such as tile overlap, are set via an INI file. 
%
% Saves the degree of down-scaling to a MAT file in the section root directory.
% Saves the original tile positions and sizes to a subdirectory as a CSV file.
% One CSV file per section. The data in these CSV files are BEFORE down-scaling. 
% 
%
% INPUTS (required)
% section -  1) a scalar (the z section in the brain). Stitches one plane only
%            2) a vector of length two [physical section, optical section]. Stitches one plane only
%            3) matrix defining the first and last planes to stitch:
%               [physSec1,optSec1; physSecN,optSecN]
%            4) a matrix defining a list of sections to stitch. one per row:
%               [physSec1,optSec1; physSec2,optSec2; ... physSecN,optSecN]
%            5) if empty, attempt to stitch from all available data directories
%
% channel - a scalar defining which channel to stitch.
% 
%
% INPUTS (optional param/value pairs)
% 'stitchedSize' - 100 (full size images) by default. If a number between 1 and 99 we save 
%                 a reduced version of the stack which has been resized by this amount. 
%                 e.g. if 50, we save a stack half the size. This is saved in a separate
%                 directory named accordingly. stitchedSize can be vector. Then we save a
%                 series of different resolutions. 
% 'overwrite'   - false by default. If false skips sections that have already been built. If true, overwrite.
% 'chessboard'  - false by default. if true do chessboard stitching (red/green overlapping tiles 
%                 to diagnose stitching quality) 
%
%
% OUTPUTS
% none
%
%
% EXAMPLES
%
% 1. Stitch section 124 channel 1
% >> stitchSection(124, 1)   
%
% 2. Stitch physical section 34, optical section 5, channel 1, and make both full size 
%    and 25% size images. 
% >> stitchSection([34,5], 1, 'stitchedSize', [100,25]) 
%
%
% 3. Stitch starting at physical section 1, optical section 1 and finishing  
%    at section 120, layer 8, channel 2, with full size and 25% size images.
% >> stitchSection([1,1; 120,8], 2, 'stitchedSize',[100,25]) 
%
% 4. Stitch section 100 channel 2 with chessboard stitching
% >> stitchSection(100, 2, 'chessboard', true)   
%
%
% Rob Campbell - Basel 2014
%
% See also - stitcher, stitchAllSections, gridPos2Pixels


%Parse non-optional input arguments
if nargin<2
	error('At least two input arguments needed')
end

if size(section,2)>2
	error('Section must be a scalar or an N by 2 array')
end

%Handle section argument
if size(section,1)<=2 
	section=handleSectionArg(section);
end

if length(channel)>1
	error('Channel must be a scalar')
end

if ~isnumeric(channel)
	error('Channel must be numeric')
end



% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
%Parse optional arguments
params = inputParser;
params.CaseSensitive = false;
params.addParamValue('stitchedSize', 100, @(x) isnumeric(x) && isscalar(x));
params.addParamValue('overwrite', false, @(x) islogical(x) || x==0 || x==1);
params.addParamValue('chessboard', false, @(x) islogical(x) || x==0 || x==1);
params.parse(varargin{:});

stitchedSize=params.Results.stitchedSize;
overwrite=params.Results.overwrite;
doChessBoard=params.Results.chessboard;
% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 


param=readMetaData2Stitchit(getTiledAcquisitionParamFile); 
userConfig=readStitchItINI;


%Extract preferences from INI file structure
doIlluminationCorrection = userConfig.tile.doIlluminationCorrection; %correct tile illumination on loading. 
doPhaseCorrection        = userConfig.tile.doPhaseCorrection;        %If 1, use saved coefficients to correct comb artifact
doStageCoords            = userConfig.stitching.doStageCoords;       %If 1 use stage coorrds instead of naive coords

%set up chessboard stitching (which is also the fusion weight variable that currently isn't interesting)
if doChessBoard==1
	fusionWeight=-1;
else
	fusionWeight=userConfig.stitching.fusionWeight;
end


baseName=directoryBaseName; %the directory base name

%Report stitching options to screen. Particularly important to do as long as 
fprintf(' Stitching parameters:\n')
fprintf('Illumination correction: %d\n', doIlluminationCorrection)
fprintf('Phase (comb) correction: %d\n', doPhaseCorrection)
if fusionWeight<0
	fprintf('Doing chessboard stitching\n')
end
fprintf('--------------------------------\n\n')


%Create directories we will use for saving the stitched data
for ii=1:length(stitchedSize)
	thisSize = stitchedSize(ii);
	reducedSizeDir{ii} = sprintf('%s_%03d', userConfig.subdir.stitchedDirBaseName, thisSize);
	if ~exist(reducedSizeDir{ii},'dir')
		fprintf('Creating empty stitched data directory tree: %s\n', reducedSizeDir{ii})
		mkdir(reducedSizeDir{ii})
	end
    thisChan=sprintf('%s%s%d',reducedSizeDir{ii},filesep,channel);
  	
    %The details directory stores tile position files
    if ~exist([thisChan,filesep,'details'],'dir')
		mkdir([thisChan,filesep,'details']) 
	end


end



numStitched=0; %The number of images stitched. This is just used for error checking
for ii=1:size(section,1) %Tile loading is done in parallel. 
	% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
	%Load the data

	%The physical section and optical section
	thisSection=section(ii,:);


	%Skip if data have already been created 
	filesExist=zeros(1,length(reducedSizeDir)); %we use this again below to only write data as needed
	if ~overwrite
		for thisR = 1:length(reducedSizeDir)
			fname = sprintf('.%s%s%s%d%ssection_%03d_%02d.tif',...
				            filesep,reducedSizeDir{thisR},filesep, channel, filesep,thisSection);
			if exist(fname, 'file')
				filesExist(thisR)=1;
			end
		end		
		if all(filesExist)
			fprintf('Files exist SKIPPING %03d/%03d -- Section %03d/%02d\n',ii,size(section,1),thisSection)
			continue
		end
	end


	[imStack,tileIndex]=tileLoad([thisSection,0,0,channel]);
		
	if isempty(imStack) %Skip if the image stack is empty. 
		fprintf('Skipping %03d/%02d due to missing tiles\n',thisSection)
		continue
	end

	fprintf('Stitching %03d/%03d -- Section %03d/%02d\n',ii,size(section,1),thisSection)

	tileIndex=tileIndex(:,4:5); %Keep only the columns we're interested in
	tileSize=size(imStack,1); %The image size (images are always square) TODO: this assumption may not always hold

	%Either stitch based on naive tile positions or stage coordinates. 
	if doStageCoords
		warning('off') %Supress annoying temporary variable warnings
		sectionName = sprintf('%s%04d',baseName,thisSection(1));
		mosaicFileName = sprintf('%s%sMosaic_%s.txt',sectionName,filesep,sectionName); %TODO: this will not work

		mosData = readMetaData2Stitchit(mosaicFileName);
		pixelPos = stagePos2PixelPos(mosData,pixRes);

		%Determine the final stitched image size as though we were not using stage coords
		naivePos=gridPos2Pixels(tileIndex,[param.voxelSize.x,param.voxelSize.y])
		naiveMaxPos=max(naivePos)+tileSize;
		naiveWidth=naiveMaxPos(1);
		naiveHeight=naiveMaxPos(2);		
		warning('on') %Supress annoying temporary variable warnings
	else %just use the naive positions
		pixelPos=gridPos2Pixels(tileIndex,[param.voxelsize.x,param.voxelsize.y]); 

	end %if doStageCoords



	[stitched,tilePosInPixels]=stitcher(imStack,pixelPos,fusionWeight);

	%If the user has asked for stage positions then we need trim back the image in order to avoid different
	%sections being different sizes
	if doStageCoords
		warning('off') %Supress annoying temporary variable warnings
		if tileSize<1E3
			trimPixels = 5;
		elseif tileSize>1E3 & tileSize<2E3
			trimPixels = 10;
		elseif tileSize>2E3
			trimPixels = 15;
		end

		stitched = stitched(1:naiveWidth-trimPixels, 1:naiveHeight-trimPixels,:);

		f=find( tilePosInPixels(:,1)==max(tilePosInPixels(:,1)) );	
		tilePosInPixels(f,2) = tilePosInPixels(f,2)-trimPixels;

		f=find( tilePosInPixels(:,3)==max(tilePosInPixels(:,3)) );
		tilePosInPixels(f,4) = tilePosInPixels(f,4)-trimPixels;
		warning('on') %Supress annoying temporary variable warnings
	end

    
	%Save full and reduced size planes
	for thisR = 1:length(reducedSizeDir)
		if filesExist(thisR), continue, end
		sectionDir = sprintf('.%s%s%s%d%s',filesep,reducedSizeDir{thisR},filesep, channel, filesep);
		sectionFname = sprintf('%ssection_%03d_%02d.tif',sectionDir,thisSection);

		imwrite(imresize(stitched,stitchedSize(thisR)/100),sectionFname,'Compression','None' )

		%also save the tile positions
		tilePosFname = sprintf('%sdetails%stilePos_%03d_%02d.csv',sectionDir,filesep,thisSection);
		saveMatrixAsCSV(tilePosInPixels,tilePosFname,'x,xwidth,y,ywidth'); %todo: save as binary instead for speed?
	end

	numStitched=numStitched+1;
end


if numStitched==0
	fprintf('\nNo images stitched by %s\n',mfilename);
	return
end

%Report back if image sizes aren't all equal for the largest images
[~,ind]=max(stitchedSize);
sectionDir = sprintf('.%s%s%s%d%s',filesep,reducedSizeDir{ind},filesep, channel, filesep);
if checkStitchedImageSizes(sectionDir)>0
	fprintf('WARNING! Stitched images are not all the same size!\n')
end


    
%Finally, write the stitching parameters to the directory. 
iniFileContents=showStitchItConf(-1);

for thisR = 1:length(reducedSizeDir)
		fname = sprintf('.%s%s%s%d%sstitchingParams.ini',...
		            filesep,reducedSizeDir{thisR},filesep, channel, filesep);

		fprintf('Logging stitching parameters to %s\n',fname)

		fid = fopen(fname,'w+');
		fprintf(fid,'%s',iniFileContents);
		fclose(fid);

		%Be extra careful and save the reduced file size
		stitchedSize = stitchedSize(thisR);
		fname = sprintf('.%s%s%s%d%sstitchedSize.mat',...
		            filesep,reducedSizeDir{thisR},filesep, channel, filesep);

		save(fname,'stitchedSize')
end

