module ModReadAmr

  ! reconstruct AMR grid and read data on this grid
  ! interpolate data

  use BATL_lib, ONLY: MaxDim

  implicit none
  save

  private !except

  ! Public methods 
  public:: readamr_read   ! read AMR data
  public:: readamr_get    ! get data at some point
  public:: readamr_clean  ! clean all variables

  ! Public data (optional)
  real, public, allocatable:: State_VGB(:,:,:,:,:) ! variables stored in blocks

  integer, public:: nVar=0                 ! number of variables in State_VGB

  character(len=20), public:: TypeGeometry = '???'
  real, public:: CoordMin_D(MaxDim) = -0.5 ! lower domain limits in gen coords
  real, public:: CoordMax_D(MaxDim) = +0.5 ! upper domain limits in gen coords

  real,    public:: TimeData = -1.0        ! simulation time of data
  integer, public:: nStepData = 0          ! time step of data
  integer, public:: nVarData = 0           ! number of variables in data file 
  integer, public:: nBlockData = 0         ! number of blocks in data file

  integer, public:: nParamData = 0         ! number of parameters in data file
  real, allocatable, public:: ParamData_I(:) ! paramters in data file

  character(len=500), public:: NameVarData  = '???' ! all variable names
  character(len=500), public:: NameUnitData = '???' ! unit names

  ! Local variables
  character(len=20):: TypeGeometryBatl = '???'
  integer:: nCellData = 0 ! number of cells in data file
  integer:: nProcData ! number of processors that wrote data file
  logical:: IsBinary  ! if the unprocessed IDL files are in binary format
  integer:: nByteReal ! number of bytes for reals in unprocessed IDL file

  character(len=5):: TypeDataFile ! type of processed file (real4/real8/ascii)

contains
  !============================================================================
  subroutine readamr_init(NameFile, IsVerbose)

    use ModIoUnit, ONLY: UnitTmp_
    use BATL_lib,  ONLY: MaxDim, nDim, nIjk, nIjk_D, iProc, nProc, init_batl
    use BATL_grid, ONLY: create_grid
    use BATL_tree, ONLY: read_tree_file, distribute_tree

    character(len=*), intent(in):: NameFile  ! base name
    logical,          intent(in):: IsVerbose ! provide verbose output

    integer:: i, iDim, iError

    character(len=500):: NameFileOrig, NameHeaderFile

    integer:: MaxBlock
    integer:: nRgen=0
    real, allocatable:: Rgen_I(:)

    real:: CellSizePlot_D(MaxDim), CellSizeMin_D(MaxDim)

    integer:: nIjkIn_D(MaxDim),  nRoot_D(nDim)
    logical:: IsPeriodic_D(MaxDim)

    character(len=*), parameter:: NameSub = 'readamr_init'
    !-------------------------------------------------------------------------
    NameHeaderFile = trim(NameFile)//'.info'
    open(UnitTmp_, file=NameHeaderFile, status='old', iostat=iError)
    if(iError /= 0) then
       NameHeaderFile = trim(NameFile)//'.h'
       open(UnitTmp_, file=NameHeaderFile, status='old', iostat=iError)
    end if
    if(iError /= 0) call CON_stop(NameSub// &
         ' ERROR: could not open '//trim(NameFile)//'.h or .info')


    if(IsVerbose) write(*,*) NameSub,' reading ',trim(NameHeaderFile)

    ! Read information from the header file
    read(UnitTmp_,'(a)') NameFileOrig
    read(UnitTmp_,*) nProcData
    read(UnitTmp_,*) nStepData
    read(UnitTmp_,*) TimeData

    if(IsVerbose) write(*,*) NameSub, &
         ' nStepData=', nStepData, ' TimeData=', TimeData

    read(UnitTmp_,*) (CoordMin_D(iDim), CoordMax_D(iDim), iDim=1,MaxDim)
    if(IsVerbose) write(*,*) NameSub, ' CoordMin_D=', CoordMin_D
    if(IsVerbose) write(*,*) NameSub, ' CoordMax_D=', CoordMax_D

    read(UnitTmp_,*) CellSizePlot_D, CellSizeMin_D, nCellData
    if(CellSizePlot_D(1) >= 0.0) call CON_stop(NameSub// &
         ': the resolution should be set to -1 for file'//trim(NameFile))
    if(IsVerbose) write(*,*) NameSub, ' nCellData=', nCellData

    ! Total number of blocks in the data file
    nBlockData = nCellData / nIjk

    ! Number of blocks per processor !!! this is wrong for box cut from sphere
    MaxBlock  = (nBlockData + nProc - 1) / nProc

    read(UnitTmp_,*) nVarData
    read(UnitTmp_,*) nParamData
    allocate(ParamData_I(nParamData))
    read(UnitTmp_,*) ParamData_I
    if(IsVerbose)then
       write(*,*) NameSub,' nVarData=',nVarData,' nParamData=', nParamData
       write(*,*) NameSub,' ParamData_I=', ParamData_I
    end if

    read(UnitTmp_,'(a)') NameVarData
    if(IsVerbose) write(*,*) NameSub,' NameVarData =',trim(NameVarData)

    read(UnitTmp_,'(a)') NameUnitData
    if(IsVerbose) write(*,*) NameSub,' NameUnitData=', trim(NameUnitData)

    read(UnitTmp_,*) IsBinary
    if(IsBinary) read(UnitTmp_,*) nByteReal

    if(IsVerbose) write(*,*) NameSub,' IsBinary, nByteReal=', &
         IsBinary, nByteReal

    read(UnitTmp_,'(a)') TypeGeometry
    if(IsVerbose) write(*,*) NameSub,' TypeGeometry=',trim(TypeGeometry)
    if(index(TypeGeometry,'genr') > 0)then
       read(UnitTmp_,*) nRgen
       if(allocated(Rgen_I)) deallocate(Rgen_I)
       allocate(Rgen_I(nRgen))
       do i = 1, nRgen
          read(UnitTmp_,*) Rgen_I(i)
       end do
       ! For some reason we store the logarithm of the radius, so take exp
       Rgen_I = exp(Rgen_I)
    else
       allocate(Rgen_I(1))
    end if

    read(UnitTmp_,'(a)') TypeDataFile  ! TypeFile for IDL data
    if(IsVerbose) write(*,*) NameSub,' TypeDataFile=', TypeDataFile

    read(UnitTmp_,*) nRoot_D
    read(UnitTmp_,*) nIjkIn_D
    read(UnitTmp_,*) IsPeriodic_D

    if(IsVerbose)then
       write(*,*) NameSub, ' nRoot_D     = ', nRoot_D
       write(*,*) NameSub, ' nIjkIn_D    = ', nIjkIn_D
       write(*,*) NameSub, ' IsPeriodic_D= ', IsPeriodic_D
    end if

    close(UnitTmp_)

    if(iProc == 0 .and. any(nIjkIn_D /= nIjk_D))then
       write(*,*) 'ERROR in ',NameSub,' while reading ',trim(NameHeaderFile)
       write(*,*) 'Block size in header file        =', nIjkIn_D
       write(*,*) 'READAMR is configured to nI,nJ,nK=', nIjk_D
       call CON_stop('Read other file or reconfigure and recompile READAMR')
    end if

    ! Initialize BATL (using generalized coordinates and radians)
    if(TypeGeometry(1:9)=='spherical') then
       TypeGeometryBatl = 'rlonlat'//TypeGeometry(10:20)
    else
       TypeGeometryBatl = TypeGeometry
    end if

    call init_batl(CoordMin_D, CoordMax_D, MaxBlock, &
         TypeGeometryBatl, rGenIn_I=rGen_I, nRootIn_D=nRoot_D, &
         IsPeriodicIn_D=IsPeriodic_D, &
         UseRadiusIn=.false., UseDegreeIn=.false.)

    ! Read the full tree information and create grid
    call read_tree_file(trim(NameFile)//'.tree')
    call distribute_tree(.true.)
    call create_grid

    deallocate(Rgen_I)

  end subroutine readamr_init
  !============================================================================
  subroutine readamr_read(NameFile, iVarIn_I, IsNewGridIn, IsVerboseIn, &
       UseCoordTest)

    use BATL_lib, ONLY: nDim, &
         MinI, MaxI, MinJ, MaxJ, MinK, MaxK, MaxBlock, nG, iProc, Xyz_DGB, &
         find_grid_block, message_pass_cell, xyz_to_coord
    use ModPlotFile, ONLY: read_plot_file
    use ModIoUnit,   ONLY: UnitTmp_
    use ModConst,    ONLY: cPi

    character(len=*), intent(in):: NameFile     ! data file name
    integer, optional, intent(in):: iVarIn_I(:) ! index of variables to store
    logical, optional, intent(in):: IsNewGridIn ! new grid (read info/tree)
    logical, optional, intent(in):: IsVerboseIn ! provide verbose output
    logical, optional, intent(in):: UseCoordTest! store cos^2(coord) into State

    logical:: IsNewGrid
    logical:: IsVerbose

    ! Allocatable arrays for holding linear file data
    real, allocatable  :: State_V(:), State_VI(:,:), Xyz_DI(:,:)

    real:: Xyz_D(MaxDim) = 0.0, Coord_D(MaxDim)
    integer:: iCell, iCell_D(MaxDim), i, j, k, l, iBlock, iProcFound, iError

    integer:: nVarLast = -1, MaxBlockLast = -1

    character(len=1):: StringTmp

    character(len=*), parameter:: NameSub = 'readamr_read'
    !--------------------------------------------------------------------------
    IsNewGrid = .true.
    if(present(IsNewGridIn)) IsNewGrid = IsNewGridIn
 
    IsVerbose = .false.
    if(present(IsVerboseIn)) IsVerbose = IsVerboseIn

    if(IsVerbose)write(*,*) NameSub,&
         ' starting with IsNewGrid, UseCoordTest,=', &
         IsNewGrid, present(UseCoordTest)

    ! Read grid info if necessary
    if(IsNewGrid)then
       l = index(NameFile,".",BACK=.true.)
       call readamr_init(NameFile(1:l-1), IsVerboseIn)
    end if

    nVar = nVarData
    if(present(iVarIn_I))then
       nVar = size(iVarIn_I)
       if(nVar>nVarData .or. any(iVarIn_I<1) .or. any(iVarIn_I>nVarData))then
          write(*,*)'ERROR: nVarData, iVarIn_I=', nVarData, iVarIn_I
          call CON_stop(NameSub//': invalid iVarIn_I array')
       end if
    end if
    if(IsVerbose)write(*,*) NameSub,' nVarData, nVar, present(iVarIn_I)=', &
         nVarData, nVar, present(iVarIn_I)

    if(.not. allocated(State_VGB) .or. &
         nVar /= nVarLast .or. MaxBlock /= MaxBlockLast)then
       if(allocated(State_VGB)) deallocate(State_VGB)
       allocate(&
            State_VGB(nVar,MinI:MaxI,MinJ:MaxJ,MinK:MaxK,MaxBlock))
       if(IsVerbose)write(*,*) NameSub,' allocated State_VGB(', &
            nVar,',',MinI,':',MaxI,',',MinJ,':',MaxJ,',',MinK,':',MaxK, &
            ',',MaxBlock,')'

       nVarLast = nVar; MaxBlockLast = MaxBlock
    end if
    State_VGB = 0.0

    ! The tests need at least nDim variables to be stored
    if(present(UseCoordTest)) nVar = max(nVar, MaxDim)

    !!! IMPLEMENT READING ALTERNATIVE FILE FORMATS !!!

    if(TypeDataFile == 'ascii')then
       open(UnitTmp_, file=NameFile, status='old', iostat=iError)
       if(iError /= 0) call CON_stop(NameSub// &
            ' ERROR: could not open ascii file '//trim(NameFile))
       ! Read and discard header lines
       do i = 1, 5
          read(UnitTmp_,*) StringTmp
       end do
       if(IsVerbose)write(*,*) NameSub,' read header lines from ascii file'
    else
       allocate(State_VI(nVarData,nCellData), Xyz_DI(nDim,nCellData))
       call read_plot_file(NameFile, TypeFileIn=TypeDataFile, &
            CoordOut_DI=Xyz_DI, VarOut_VI = State_VI)
    end if

    ! State variables for one cell
    allocate(State_V(nVarData))

    ! put each data point into the tree
    do iCell = 1, nCellData
       ! find cell on the grid
       if(TypeDataFile == 'ascii')then
          read(UnitTmp_,*) Xyz_D(1:nDim), State_V
       else
          Xyz_D(1:nDim) = Xyz_DI(:,iCell)
          State_V = State_VI(:,iCell)
       end if
       call find_grid_block(Xyz_D, iProcFound, iBlock, iCell_D)

       if(iBlock < 0)then
          write(*,*)'ERROR for iCell, Xyz_D=', iCell, Xyz_D
          call CON_stop(NameSub//': could not find cell on the grid')
       end if

       !check if point belongs on this processor
       if (iProcFound /= iProc) CYCLE

       i = iCell_D(1); j = iCell_D(2); k = iCell_D(3)

       if(any(abs(Xyz_DGB(:,i,j,k,iBlock) - Xyz_D) > 1e-5))then
          write(*,*)NameSub,' ERROR at iCell,i,j,k,iBlock,iProc=', &
               iCell, i, j, k, iBlock, iProc
          write(*,*)NameSub,' Xyz_D  =', Xyz_D
          write(*,*)NameSub,' Xyz_DGB=', Xyz_DGB(:,i,j,k,iBlock)
          call CON_stop(NameSub//': incorrect coordinates')
       end if

       if(present(iVarIn_I))then
          State_VGB(:,i,j,k,iBlock) = State_V(iVarIn_I)
       else
          State_VGB(:,i,j,k,iBlock) = State_V
       end if

       ! For verification tests
       if(present(UseCoordTest))then
          ! Store cos^2 of generalized coordinates into first MaxDim elements
          call xyz_to_coord(Xyz_D, Coord_D)
          State_VGB(1:MaxDim,i,j,k,iBlock) = &
               cos(cPi*(Coord_D - CoordMin_D)/(CoordMax_D - CoordMin_D))**2
       end if

    enddo

    if(TypeDataFile == 'ascii') close(UnitTmp_)

    if(IsVerboseIn)write(*,*)NameSub,' read data'

    ! deallocate to save memory
    deallocate(State_V)
    if(allocated(State_VI)) deallocate (State_VI, Xyz_DI) 

    ! Set ghost cells if any. Note that OUTER ghost cells are not set!
    if(nG > 0) call message_pass_cell(nVar, State_VGB)

    if(IsVerboseIn)write(*,*)NameSub,' done'

  end subroutine readamr_read

  !============================================================================
  subroutine readamr_get(Xyz_D, State_V, IsFound)

    use BATL_lib, ONLY: nDim, nG, nIJK_D, iProc, Xyz_DGB, &
         interpolate_grid, find_grid_block

    real,    intent(in)  :: Xyz_D(MaxDim)   ! location on grid
    real,    intent(out) :: State_V(0:nVar) ! weight and variables
    logical, intent(out) :: IsFound         ! true if found on grid

    ! Block and processor index for the point
    integer:: iBlock, iProcOut

    ! Variables for linear interpolation using ghost cells
    integer:: i1, j1=1, k1=1, i2, j2, k2
    real:: Dist_D(MaxDim), Dx1, Dx2, Dy1, Dy2, Dz1, Dz2

    ! Variables for AMR interpolation without ghost cells
    integer:: iCell, nCell, iCell_II(0:nDim,2**nDim), iCell_D(MaxDim), i, j, k
    real:: Weight_I(2**nDim)

    logical, parameter:: DoDebug = .false.

    character(len=*), parameter:: NameSub='readamr_get'
    !-------------------------------------------------------------------------
    if(DoDebug)write(*,*)NameSub,' starting with Xyz_D=', Xyz_D

    State_V = 0.0

    call find_grid_block(Xyz_D, iProcOut, iBlock, iCell_D, Dist_D)
    if(DoDebug)write(*,*)NameSub,&
         ' found iProcOut, iBlock, iCell_D, Dist_D=', &
         iProcOut, iBlock, iCell_D, Dist_D

    IsFound = iBlock > 0
    if(.not.IsFound) RETURN

    ! Check if all surrounding cells are inside a single block
    if(all(iCell_D(1:nDim) > 0 .and. iCell_D(1:nDim) < nIJK_D(1:nDim)))then
       
       if(iProcOut /= iProc) RETURN

       ! Set weight to 1.0
       State_V(0) = 1.0

       ! Set indexes and distances for interpolation
       Dx1 = Dist_D(1); Dx2 = 1 - Dx1
       i1  = iCell_D(1); i2 = i1 + 1
       if(nDim > 1)then
          Dy1 = Dist_D(2); Dy2 = 1 - Dy1
          j1 = iCell_D(2); j2 = j1 + 1
       end if
       if(nDim > 2)then
          Dz1 = Dist_D(3); Dz2 = 1 - Dz1
          k1 = iCell_D(3); k2 = k1 + 1
       end if

       ! Interpolate
       if(nDim == 1)then
          State_V(1:nVar) = Dx2*State_VGB(:,i1,j1,k1,iBlock)  &
               +            Dx1*State_VGB(:,i2,j1,k1,iBlock)
       end if
       if(nDim == 2)then
          State_V(1:nVar) = Dy2*(Dx2*State_VGB(:,i1,j1,k1,iBlock)   &
               +                 Dx1*State_VGB(:,i2,j1,k1,iBlock))  &
               +            Dy1*(Dx2*State_VGB(:,i1,j2,k1,iBlock)   &
               +                 Dx1*State_VGB(:,i2,j2,k1,iBlock))
       end if
       if(nDim == 3)then
          State_V(1:nVar) = Dz2*(Dy2*(Dx2*State_VGB(:,i1,j1,k1,iBlock)   &
               +                      Dx1*State_VGB(:,i2,j1,k1,iBlock))  &
               +                 Dy1*(Dx2*State_VGB(:,i1,j2,k1,iBlock)   &
               +                      Dx1*State_VGB(:,i2,j2,k1,iBlock))) &
               +            Dz1*(Dy2*(Dx2*State_VGB(:,i1,j1,k2,iBlock)   &
               +                      Dx1*State_VGB(:,i2,j1,k2,iBlock))  &
               +                 Dy1*(Dx2*State_VGB(:,i1,j2,k2,iBlock)   &
               +                      Dx1*State_VGB(:,i2,j2,k2,iBlock)))
       end if

       if(DoDebug)then
          write(*,*)'!!! i1,j1,k1,i2,j2,k2=',i1,j1,k1,i2,j2,k2
          write(*,*)'!!! Dx1,Dx2,Dy1,Dy2,Dz1,Dz2=',Dx1,Dx2,Dy1,Dy2,Dz1,Dz2
          write(*,*)'!!! State_VGB(1,i1:i2,j1:j2,k1:k2,iBlock) = ',&
               State_VGB(1,i1:i2,j1:j2,k1:k2,iBlock)
       end if

    else
       ! Use interpolation algorithm that does not rely on ghost cells at all
       call interpolate_grid(Xyz_D, nCell, iCell_II, Weight_I)

       if(DoDebug)write(*,*)NameSub,': interpolate iProc, nCell=',iProc, nCell

       do iCell = 1, nCell
          iBlock  = iCell_II(0,iCell)
          iCell_D = 1
          iCell_D(1:nDim) = iCell_II(1:nDim,iCell)
          i      = iCell_D(1)
          j      = iCell_D(2)
          k      = iCell_D(3)
          if(DoDebug)write(*,*)NameSub,': iProc,iBlock,i,j,k,=',&
               iProc, iBlock, i, j, k

          State_V(0) = State_V(0)  + Weight_I(iCell)
          State_V(1:nVar) = State_V(1:nVar) &
               + Weight_I(iCell)*State_VGB(:,i,j,k,iBlock)

          if(DoDebug)write(*,*)NameSub, ': iProc,iBlock,i,j,k,Xyz,State=', &
               iProc, iBlock, i, j, k, &
               Xyz_DGB(:,i,j,k,iBlock), State_VGB(0:nDim,i,j,k,iBlock)
       end do
    end if

    if(DoDebug)write(*,*)NameSub,' finished with State_V=', State_V

  end subroutine readamr_get
  !============================================================================
  subroutine readamr_clean
    use BATL_lib, ONLY: clean_batl

    call clean_batl
    if(allocated(State_VGB)) deallocate(State_VGB)
    if(allocated(ParamData_I)) deallocate(ParamData_I)
    nVar       = 0
    nVarData   = 0
    nBlockData = 0

  end subroutine readamr_clean

end module ModReadAmr
