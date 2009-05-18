module BATL_tree

  use BATL_size, ONLY: MaxBlock

  implicit none
  save

  private ! except

  public:: init_mod_tree
  public:: set_root_block
  public:: refine_block
  public:: coarsen_block
  public:: get_block_position
  public:: find_point
  public:: write_tree_file
  public:: read_tree_file
  public:: test_tree

  integer, public, parameter :: MaxDim = 3   ! This has to be 3 all the time
  integer, public, parameter :: nDim   = 3   ! This can be 1, 2 or 3

  integer, public, parameter :: nChild = 2**nDim

  integer, public, allocatable :: iTree_IA(:,:)

  integer, public, parameter :: &
       Status_   = 1, &
       Level_    = 2, &
       LevelMin_ = 3, &
       LevelMax_ = 4, &
       Parent_   = 5, & ! Parent must be just before the first child!
       Child0_   = 5, &
       Child1_   = Child0_ + 1,      &
       ChildLast_= Child0_ + nChild, &
       Proc_     = Child0_ + 1,      & ! Overlaps with child 1
       Block_    = Child0_ + 2,      & ! Overlaps with child 2
       Coord0_   = ChildLast_,       &
       Coord1_   = Coord0_ + 1,      &
       CoordLast_= Coord0_ + MaxDim

  ! Deepest AMR level relative to root blocks (limited by 32 bit integers)
  integer, public, parameter :: MaxLevel = 30

  ! The maximum integer coordinate for a given level below root blocks
  ! The loop variable has to be declared to work-around NAG f95 bug
  integer :: L__
  integer, public, parameter :: &
       MaxCoord_I(0:MaxLevel) = (/ (2**L__, L__=0,MaxLevel) /)

  ! The number of root blocks in all dimensions, and altogether
  integer, public :: nRoot_D(MaxDim) = 0, nRoot = 0

  ! Local variables

  character(len=*), parameter:: NameMod = "BATL_tree"

  integer, parameter :: UnitTmp_ = 9 ! same as used in SWMF

  ! Number of items stored in iTree_IA
  integer, parameter :: nInfo = CoordLast_

  ! Possible values for the status variable
  integer, parameter :: Skipped_=0, Unused_=1, Used_=2, Refine_=3, Coarsen_=4

  ! Index for non-existing block and level differences
  integer, parameter :: NoBlock_ = -100

  ! Neighbor information
  integer, allocatable :: DiLevelNei_IIIB(:,:,:,:), iBlockNei_IIIB(:,:,:,:)

  ! Maximum number of blocks including unused and skipped ones
  integer :: MaxBlockAll = 0

  ! Number of used blocks (leaves of the block tree)
  integer :: nBlockUsed = 0

  ! Number of levels below root in level (that has occured at any time)
  integer :: nLevel = 0

  ! Periodicity of the domain per dimension
  logical :: IsPeriodic_D(MaxDim) = .false.

  ! Cylindrical or spherical coordinates
  logical :: IsSpherical = .false., IsCylindrical = .false.

  ! Ordering along the Peano-Hilbert space filling curve
  integer, allocatable :: iBlockPeano_I(:)

  ! The index along the Peano curve is global so that it can be used by the 
  ! recursive subroutine order_children 
  integer :: iPeano

contains

  subroutine init_mod_tree(nBlockProc, nBlockAll)

    ! Initialize the tree array with nBlock blocks

    integer, intent(in) :: nBlockProc ! Max number of blocks per processor
    integer, intent(in) :: nBlockAll  ! Max number of blocks altogether
    !----------------------------------------------------------------------
    if(allocated(iTree_IA)) RETURN

    MaxBlockAll = nBlockAll
    allocate(iTree_IA(nInfo, MaxBlockAll))

    ! Initialize all elements and make blocks skipped
    iTree_IA = Skipped_

    MaxBlock = nBlockProc
    allocate(iBlockNei_IIIB(0:3,0:3,0:3,MaxBlock))
    allocate(DiLevelNei_IIIB(-1:1,-1:1,-1:1,MaxBlock))
    allocate(iBlockPeano_I(MaxBlock))

    ! Initialize all elements and make neighbors unknown
    iBlockNei_IIIB  = NoBlock_
    DiLevelNei_IIIB = NoBlock_
    iBlockPeano_I   = NoBlock_

  end subroutine init_mod_tree

  !==========================================================================

  integer function i_block_new()

    ! Find a skipped element in the iTree_IA array

    integer :: iBlock

    do iBlock = 1, MaxBlockAll
       if(iTree_IA(Status_, iBlock) == Skipped_)then
          i_block_new = iBlock
          return
       end if
    end do
    ! Could not find any skipped block
    i_block_new = -1

  end function i_block_new

  !==========================================================================

  subroutine set_root_block(nRootIn_D, IsPeriodicIn_D)

    integer, intent(in) :: nRootIn_D(MaxDim)
    logical, intent(in) :: IsPeriodicIn_D(MaxDim)

    integer :: iRoot, jRoot, kRoot, iBlock, Ijk_D(MaxDim)
    !-----------------------------------------------------------------------

    nRoot_D      = nRootIn_D
    nRoot        = product(nRoot_D)
    IsPeriodic_D = IsPeriodicIn_D

    ! Use the first product(nRoot_D) blocks as root blocks in the tree
    iBlock = 0
    do kRoot = 1, nRoot_D(3)
       do jRoot = 1, nRoot_D(2)
          do iRoot = 1, nRoot_D(1)

             Ijk_D = (/ iRoot, jRoot, kRoot /)

             iBlock = iBlock + 1
             iTree_IA(Status_, iBlock)            = Used_
             iTree_IA(Parent_, iBlock)            = NoBlock_
             iTree_IA(Child1_:ChildLast_, iBlock) = NoBlock_
             iTree_IA(Level_ , iBlock)            = 0
             iTree_IA(Coord1_:CoordLast_, iBlock) = Ijk_D

          end do
       end do
    end do

    nBlockUsed = nRoot

    ! Set neighbor info
    !do iBlock = 1, nRoot
    !   call find_neighbors(iBlock)
    !end do

  end subroutine set_root_block

  !==========================================================================
  subroutine refine_block(iBlock)

    integer, intent(in) :: iBlock

    integer :: iChild, DiChild, iLevelChild, iProc, iBlockProc, iCoord_D(nDim)
    integer :: iDim, iBlockChild
    !----------------------------------------------------------------------

    iTree_IA(Status_, iBlock) = Unused_

    iLevelChild = iTree_IA(Level_, iBlock) + 1
    iProc       = iTree_IA(Proc_,  iBlock)
    iBlockProc  = iTree_IA(Block_, iBlock)

    ! Keep track of number of levels
    nLevel = max(nLevel, iLevelChild)
    if(nLevel > MaxLevel) &
         call CON_stop('Error in refine_block: too many levels')

    iCoord_D = 2*iTree_IA(Coord1_:Coord0_+nDim, iBlock) - 1

    do iChild = Child1_, ChildLast_

       iBlockChild = i_block_new()

       iTree_IA(iChild, iBlock) = iBlockChild

       iTree_IA(Status_,   iBlockChild) = Used_
       iTree_IA(Level_,    iBlockChild) = iLevelChild
       iTree_IA(LevelMin_, iBlockChild) = iTree_IA(LevelMin_, iBlock)
       iTree_IA(LevelMax_, iBlockChild) = iTree_IA(LevelMax_, iBlock)
       iTree_IA(Parent_,   iBlockChild) = iBlock
       iTree_IA(Child1_:ChildLast_, iBlockChild) = NoBlock_

       ! This overwrites the two first children (saves memory)
       iTree_IA(Proc_,     iBlockChild) = iProc
       iTree_IA(Block_,    iBlockChild) = iBlockProc

       ! Calculate the coordinates of the child block
       DiChild = iChild - Child1_
       do iDim = 1, nDim
          iTree_IA(Coord0_+iDim, iBlockChild) = &
               iCoord_D(iDim) + ibits(DiChild, iDim-1, 1)
       end do

    end do

    nBlockUsed = nBlockUsed + nChild - 1

    ! Find neighbors of children
    !do iChild = Child1_, ChildLast_
    !
    !   iBlockChild = iTree_IA(iChild, iBlock)
    !   call find_neighbors(iBlockChild)
    !
    !end do

    ! Should also redo neighbors of the parent block

  end subroutine refine_block

  !==========================================================================
  subroutine coarsen_block(iBlock)

    integer, intent(in) :: iBlock

    integer :: iChild, iBlockChild1, iBlockChild
    !-----------------------------------------------------------------------

    do iChild = Child1_, ChildLast_
       iBlockChild = iTree_IA(iChild, iBlock)

       ! Wipe out the child block
       iTree_IA(Status_, iBlockChild) = Skipped_
    end do

    ! Make this block used with no children
    iTree_IA(Status_, iBlock) = Used_

    iBlockChild1 = iTree_IA(Child1_, iBlock)
    iTree_IA(Child1_:ChildLast_, iBlock) = NoBlock_

    ! set proc and block info from child1
    iTree_IA(Proc_,  iBlock) = iTree_IA(Proc_,  iBlockChild1)
    iTree_IA(Block_, iBlock) = iTree_IA(Block_, iBlockChild1)

    nBlockUsed = nBlockUsed - nChild + 1

  end subroutine coarsen_block

  !==========================================================================
  subroutine get_block_position(iBlock, PositionMin_D, PositionMax_D)

    integer, intent(in) :: iBlock
    real,    intent(out):: PositionMin_D(MaxDim), PositionMax_D(MaxDim)

    ! Calculate normalized position of the edges of block iblock.
    ! Zero is at the minimum boundary of the grid, one is at the max boundary

    integer :: iLevel
    !------------------------------------------------------------------------
    iLevel = iTree_IA(Level_, iBlock)

    ! Convert to real by adding -1.0 or 0.0 for the two edges, respectively
    PositionMin_D = (iTree_IA(Coord1_:CoordLast_,iBlock) - 1.0) &
         /MaxCoord_I(iLevel)/nRoot_D
    PositionMax_D = (iTree_IA(Coord1_:CoordLast_,iBlock) + 0.0) &
         /MaxCoord_I(iLevel)/nRoot_D

  end subroutine get_block_position

  !==========================================================================
  subroutine find_point(CoordIn_D, iBlock)

    ! Find the block that contains a point. The point coordinates should
    ! be given in generalized coordinates normalized to the domain size:
    ! CoordIn_D = (CoordOrig_D - CoordMin_D)/(CoordMax_D-CoordMin_D)

    real, intent(in):: CoordIn_D(MaxDim)
    integer, intent(out):: iBlock

    real :: Coord_D(MaxDim)
    integer :: iLevel, iChild
    integer :: Ijk_D(MaxDim), iCoord_D(nDim), iBit_D(nDim)
    !----------------------------------------------------------------------
    ! Scale coordinates so that 1 <= Coord_D <= nRoot_D+1
    Coord_D = 1.0 + nRoot_D*max(0.0, min(1.0, CoordIn_D))

    ! Get root block index
    Ijk_D = min(int(Coord_D), nRoot_D)

    ! Root block indexes are ordered
    iBlock = Ijk_D(1) + nRoot_D(1)*((Ijk_D(2)-1) + nRoot_D(2)*(Ijk_D(3)-1))

    if(iTree_IA(Status_, iBlock) == Used_) RETURN

    ! Get normalized coordinates within root block and scale it up
    ! to the largest resolution
    iCoord_D = (Coord_D(1:nDim) - Ijk_D(1:nDim))*MaxCoord_I(nLevel)

    ! Go down the tree using bit information
    do iLevel = nLevel-1,0,-1
       iBit_D = ibits(iCoord_D, iLevel, 1)
       iChild = sum(iBit_D*MaxCoord_I(0:nDim-1)) + Child1_
       iBlock = iTree_IA(iChild, iBlock)

       if(iTree_IA(Status_, iBlock) == Used_) RETURN
    end do


  end subroutine find_point

  !==========================================================================
  logical function is_point_inside_block(Position_D, iBlock)

    ! Check if position is inside block or not

    real,    intent(in):: Position_D(MaxDim)
    integer, intent(in):: iBlock

    real    :: PositionMin_D(MaxDim), PositionMax_D(MaxDim)
    !-------------------------------------------------------------------------
    call get_block_position(iBlock, PositionMin_D, PositionMax_D)

    ! Include min edge but exclude max edge for sake of uniqueness
    is_point_inside_block = &
         all(Position_D >= PositionMin_D) .and. &
         all(Position_D <  PositionMax_D)

  end function is_point_inside_block

  !===========================================================================

  subroutine find_neighbors(iBlock)

    integer, intent(in):: iBlock

    integer :: iLevel, i, j, k, Di, Dj, Dk, jBlock
    real :: Scale_D(MaxDim), x, y, z
    !-----------------------------------------------------------------------

    ! We should convert local block into global block index or vice-versa

    iLevel  = iTree_IA(Level_, iBlock)
    Scale_D = (1.0/MaxCoord_I(iLevel))/nRoot_D
    do k=0,3
       Dk = nint((k - 1.5)/1.5)
       if(nDim < 3)then
          if(k/=1) CYCLE
          z = 0.3
       else
          z = (iTree_IA(CoordLast_, iBlock) + 0.4*k - 1.1)*Scale_D(3)
          if(z > 1.0 .or. z < 0.0)then
             if(IsPeriodic_D(3))then
                z = modulo(z, 1.0)
             else
                iBlockNei_IIIB(:,:,k,iBlock) = NoBlock_
                DiLevelNei_IIIB(:,:,Dk,iBlock) = NoBlock_
                CYCLE
             end if
          end if
       end if
       do j=0,3
          Dj = nint((j - 1.5)/1.5)
          if(nDim < 2)then
             if(j/=1) CYCLE
             y = 0.3
          else
             y = (iTree_IA(Coord0_+2, iBlock) + 0.4*j - 1.1)*Scale_D(2)
             if(y > 1.0 .or. y < 0.0)then
                if(IsPeriodic_D(2))then
                   y = modulo(y, 1.0)
                elseif(IsSpherical)then
                   ! Push back theta and go around half way in phi
                   y = max(0.0, min(1.0, y))
                   z = modulo( z+0.5, 1.0)
                else
                   iBlockNei_IIIB(:,j,k,iBlock) = NoBlock_
                   DiLevelNei_IIIB(:,Dj,Dk,iBlock) = NoBlock_
                   CYCLE
                end if
             end if
          end if
          do i=0,3
             ! Exclude inner points
             if(0<i.and.i<3.and.0<j.and.j<3.and.0<k.and.k<3) CYCLE

             Di = nint((i - 1.5)/1.5)

             ! If neighbor is not finer, fill in the i=2 or j=2 or k=2 elements
             if(DiLevelNei_IIIB(Di,Dj,Dk,iBlock) >= 0)then
                if(i==2)then
                   iBlockNei_IIIB(i,j,k,iBlock) = iBlockNei_IIIB(1,j,k,iBlock)
                   CYCLE
                end if
                if(j==2)then
                   iBlockNei_IIIB(i,j,k,iBlock) = iBlockNei_IIIB(i,1,k,iBlock)
                   CYCLE
                end if
                if(k==2)then
                   iBlockNei_IIIB(i,j,k,iBlock) = iBlockNei_IIIB(i,j,1,iBlock)
                   CYCLE
                end if
             end if

             x = (iTree_IA(Coord1_, iBlock) + 0.4*i - 1.1)*Scale_D(1)
             if(x > 1.0 .or. x < 0.0)then
                if(IsPeriodic_D(1))then
                   x = modulo(x, 1.0)
                elseif(IsCylindrical .and. x < 0.0)then
                   ! Push back radius and go around half way in phi direction
                   x = 0.0
                   z = modulo( z+0.5, 1.0)
                else
                   iBlockNei_IIIB(i,j,k,iBlock) = NoBlock_
                   DiLevelNei_IIIB(Di,Dj,Dk,iBlock) = NoBlock_
                   CYCLE
                end if
             end if

             call find_point( (/x, y, z/), jBlock)
             iBlockNei_IIIB(i,j,k,iBlock) = jBlock
             DiLevelNei_IIIB(Di,Dj,Dk,iBlock) = &
                  iLevel - iTree_IA(Level_, jBlock)
          end do
       end do
    end do

  end subroutine find_neighbors

  !==========================================================================

  subroutine compact_tree(nBlockAll)

    ! Eliminate holes from the tree

    integer, intent(out), optional:: nBlockAll

    ! Amount of shift for each block
    integer, allocatable:: iBlockNew_A(:)
    integer :: iBlock, iBlockSkipped, iBlockOld, i
    !-------------------------------------------------------------------------
    allocate(iBlockNew_A(MaxBlockAll))

    ! Set impossible initial values
    iBlockNew_A = NoBlock_
    iBlockSkipped = MaxBlockAll + 1

    do iBlock = 1, MaxBlockAll

       if(iTree_IA(Status_, iBlock) == Skipped_)then
          ! Store the first skipped position
          iBlockSkipped = min(iBlockSkipped, iBlock)
       elseif(iBlockSkipped < iBlock)then
          ! Move block to the first skipped position
          iTree_IA(:,iBlockSkipped) = iTree_IA(:,iBlock)
          iTree_IA(Status_, iBlock) = Skipped_
          ! Store new block index
          iBlockNew_A(iBlock) = iBlockSkipped
          ! Advance iBlockSkipped
          iBlockSkipped = iBlockSkipped + 1
       else
          ! The block did not move
          iBlockNew_A(iBlock) = iBlock
       endif
    end do

    ! Apply shifts
    do iBlock = 1, MaxBlockAll

       if(iTree_IA(Status_, iBlock) == Skipped_) EXIT
       write(*,*)'iBlock, Status=',iBlock,iTree_IA(:, iBlock)
       do i = Parent_, ChildLast_
          iBlockOld = iTree_IA(i, iBlock)
          if(iBlockOld /= NoBlock_) &
               iTree_IA(i, iBlock) = iBlockNew_A(iBlockOld)
       end do

    end do

    ! Fix the block indexes along the Peano curve
    do iPeano = 1, nBlockUsed
       iBlockOld = iBlockPeano_I(iPeano)
       iBlockPeano_I(iPeano) = iBlockNew_A(iBlockOld)
    end do

    if(present(nBlockAll)) nBlockAll = iBlock - 1

  end subroutine compact_tree

  !==========================================================================

  subroutine write_tree_file(NameFile)

    character(len=*), intent(in):: NameFile
    integer :: nBlockAll

    !-------------------------------------------------------------------------
    call compact_tree(nBlockAll)
    open(UnitTmp_, file=NameFile, status='replace', form='unformatted')

    write(UnitTmp_) nBlockAll, nInfo
    write(UnitTmp_) nDim, nRoot_D
    write(UnitTmp_) iTree_IA(:,1:nBlockAll)

    close(UnitTmp_)

  end subroutine write_tree_file
  
  !==========================================================================

  subroutine read_tree_file(NameFile)

    character(len=*), intent(in):: NameFile
    integer :: nInfoIn, nBlockIn, nDimIn, nRootIn_D(MaxDim)
    character(len=*), parameter :: NameSub = 'read_tree_file'
    !----------------------------------------------------------------------

    open(UnitTmp_, file=NameFile, status='old', form='unformatted')

    read(UnitTmp_) nBlockIn, nInfoIn
    if(nBlockIn > MaxBlock)then
       write(*,*) NameSub,' nBlockIn, MaxBlock=',nBlockIn, MaxBlock 
       call CON_stop(NameSub//' too many blocks in tree file!')
    end if
    read(UnitTmp_) nDimIn, nRootIn_D
    if(nDimIn /= nDim)then
       write(*,*) NameSub,' nDimIn, nDim=',nDimIn, nDim
       call CON_stop(NameSub//' nDim is different in tree file!')
    end if
    call set_root_block(nRootIn_D, IsPeriodic_D)
    read(UnitTmp_) iTree_IA(:,1:nBlockIn)
    close(UnitTmp_)

    call order_tree

  end subroutine read_tree_file
  
  !==========================================================================

  subroutine order_tree

    integer :: iBlock, iRoot, jRoot, kRoot
    !-----------------------------------------------------------------------
    iBlock = 0
    iPeano = 0
    iBlockPeano_I = NoBlock_
    do kRoot = 1, nRoot_D(3)
       do jRoot = 1, nRoot_D(2)
          do iRoot = 1, nRoot_D(1)
             ! Root blocks are the first ones
             iBlock = iBlock + 1

             ! All root blocks are handled as if they were first child
             call order_children(iBlock, Child1_)
          end do
       end do
    end do

    nBlockUsed = iPeano

  end subroutine order_tree
  !==========================================================================
  recursive subroutine order_children(iBlock, iChildMe)

    integer, intent(in) :: iBlock, iChildMe
    integer :: iChild
    !-----------------------------------------------------------------------
    if(iTree_IA(Status_, iBlock) == Used_)then
       iPeano = iPeano + 1
       iBlockPeano_I(iPeano) = iBlock
    else
       do iChild = Child1_, ChildLast_
          ! iChild = iChildOrder_II(i, iChildMe)
          call order_children(iTree_IA(iChild, iBlock), iChild)
       end do
    end if

  end subroutine order_children
  !==========================================================================

  subroutine test_tree

    integer :: iBlock, nBlockAll, Int_D(MaxDim)
    real:: CoordTest_D(MaxDim)
 
    character(len=*), parameter :: NameSub = 'test_tree'
    !-----------------------------------------------------------------------

    write(*,*)'Testing init_mod_tree'
    call init_mod_tree(50, 100)
    if(MaxBlock /= 50) &
         write(*,*)'init_mod_octtree faild, MaxBlock=',&
         MaxBlock, ' should be 50'

    if(MaxBlockAll /= 100) &
         write(*,*)'init_mod_octtree faild, MaxBlockAll=',&
         MaxBlockAll, ' should be 100'

    write(*,*)'Testing i_block_new()'
    iBlock = i_block_new()
    if(iBlock /= 1) &
         write(*,*)'i_block_new() failed, iBlock=',iBlock,' should be 1'

    write(*,*)'Testing set_root_block'
    call set_root_block( (/1,2,3/), (/.true., .true., .false./) )

    if(any( nRoot_D /= (/1,2,3/) )) &
         write(*,*) 'set_root_block failed, nRoot_D=',nRoot_D,&
         ' should be 1,2,3'

    Int_D = (/1,2,2/)

    if(any( iTree_IA(Coord1_:CoordLast_,4) /= Int_D(1:nDim) )) &
         write(*,*) 'set_root_block failed, coordinates of block four=',&
         iTree_IA(Coord1_:CoordLast_,4), ' should be ',Int_D(1:nDim)

    write(*,*)'Testing find_point'
    CoordTest_D = (/0.99,0.99,0.9/)
    call find_point(CoordTest_D, iBlock)
    if(iBlock /= nRoot)write(*,*)'ERROR: Test find point failed, iBlock=',&
         iBlock,' instead of',nRoot

    if(.not.is_point_inside_block(CoordTest_D, iBlock)) &
         write(*,*)'ERROR: Test find point failed'
    
    write(*,*)'Testing refine_block'
    ! Refine the block where the point was found and find it again
    call refine_block(iBlock)

    call find_point(CoordTest_D,iBlock)
    if(.not.is_point_inside_block(CoordTest_D, iBlock)) &
         write(*,*)'ERROR: Test find point failed'

    ! Refine another block
    write(*,*)'nRoot=',nRoot
    call refine_block(nRoot-2)

    write(*,*)'Testing find_neighbors'
    call find_neighbors(5)
    write(*,*)'DiLevelNei_IIIB(:,:,:,5)=',DiLevelNei_IIIB(:,:,:,5)
    write(*,*)'iBlockNei_IIIB(:,:,:,5)=',iBlockNei_IIIB(:,:,:,5)

    write(*,*)'Testing order_tree 1st'
    call order_tree
    write(*,*)'iBlockPeano_I =',iBlockPeano_I(1:22)

    write(*,*)'Testing coarsen_block'

    ! Coarsen back the last root block and find point again
    call coarsen_block(nRoot)
    call find_point(CoordTest_D,iBlock)
    if(iBlock /= nRoot)write(*,*)'ERROR: coarsen_block faild, iBlock=',&
         iBlock,' instead of',nRoot
    if(.not.is_point_inside_block(CoordTest_D, iBlock)) &
         write(*,*)'ERROR: is_point_inside_block failed'


    write(*,*)'Testing order_tree 2nd'
    call order_tree
    write(*,*)'iBlockPeano_I =',iBlockPeano_I(1:22)


    write(*,*)'Testing compact_tree'
    call compact_tree(nBlockAll)
    if(iTree_IA(Status_, nBlockAll+1) /= Skipped_) &
         write(*,*)'ERROR: compact_tree faild, nBlockAll=', nBlockAll, &
         ' but status of next block is', iTree_IA(Status_, nBlockAll+1), &
         ' instead of ',Skipped_
    if(any(iTree_IA(Status_, 1:nBlockAll) == Skipped_)) &
         write(*,*)'ERROR: compact_tree faild, nBlockAll=', nBlockAll, &
         ' but iTree_IA(Status_, 1:nBlockAll)=', &
         iTree_IA(Status_, 1:nBlockAll),' contains skipped=',Skipped_
    call find_point(CoordTest_D,iBlock)
    if(iBlock /= nRoot)write(*,*)'ERROR: compact_tree faild, iBlock=',&
         iBlock,' instead of',nRoot
    if(.not.is_point_inside_block(CoordTest_D, iBlock)) &
         write(*,*)'ERROR: is_point_inside_block failed'

    write(*,*)'Testing order_tree 3rd'
    call order_tree
    write(*,*)'iBlockPeano_I =',iBlockPeano_I(1:22)

    write(*,*)'Testing write_tree_file'
    call write_tree_file('tree.rst')

    write(*,*)'Testing read_tree_file'
    iTree_IA = NoBlock_
    nRoot_D = 0
    call read_tree_file('tree.rst')

    call find_point(CoordTest_D,iBlock)
    if(iBlock /= nRoot)write(*,*)'ERROR: compact_tree faild, iBlock=',&
         iBlock,' instead of',nRoot

    write(*,*)'Testing order_tree 4th'
    call order_tree
    write(*,*)'iBlockPeano_I =',iBlockPeano_I(1:22)

    
  end subroutine test_tree

end module BATL_tree
