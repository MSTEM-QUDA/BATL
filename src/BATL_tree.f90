module BATL_tree

  use BATL_size, ONLY: MaxBlock, MaxDim, nDimTree

  implicit none
  save

  private ! except

  public:: init_tree
  public:: clean_tree
  public:: set_tree_root
  public:: refine_tree_block
  public:: coarsen_tree_block
  public:: get_tree_position
  public:: find_tree_block
  public:: distribute_tree
  public:: write_tree_file
  public:: read_tree_file
  public:: test_tree

  integer, public, parameter :: nChild = 2**nDimTree

  integer, public, allocatable :: iTree_IA(:,:)

  integer, public, parameter :: &
       Status_   =  1, &
       Level_    =  2, &
       Proc_     =  3, &
       Block_    =  4, &
       ProcNew_  =  5, &
       BlockNew_ =  6, &
       Coord0_   =  6, &
       Coord1_   =  7, &
       CoordLast_=  9, &
       Parent_   = 10, & ! Parent must be just before the first child!
       Child0_   = 10, &
       Child1_   = Child0_ + 1,      &
       ChildLast_= Child0_ + nChild

  ! Number of items stored in iTree_IA
  integer, parameter :: nInfo = ChildLast_

  character(len=10), parameter:: NameTreeInfo_I(Child0_+8) = (/ &
       'Status   ', &
       'Level    ', &
       'Proc     ', &
       'Block    ', &
       'ProcNew  ', &
       'BlockNew ', &
       'Coord1   ', &
       'Coord2   ', &
       'Coord3   ', &
       'Parent   ', &
       'Child1   ', &
       'Child2   ', &
       'Child3   ', &
       'Child4   ', &
       'Child5   ', &
       'Child6   ', &
       'Child7   ', &
       'Child8   ' /)

  ! Mapping from local block and processor index to global node index
  integer, public, allocatable :: iNode_BP(:,:)

  ! Local variables -----------------------------------------------

  ! Deepest AMR level relative to root blocks (limited by 32 bit integers)
  integer, parameter :: MaxLevel = 30

  ! The maximum integer coordinate for a given level below root blocks
  ! The loop variable has to be declared to work-around NAG f95 bug
  integer :: L__
  integer, parameter :: &
       MaxCoord_I(0:MaxLevel) = (/ (2**L__, L__=0,MaxLevel) /)

  ! The number of root blocks in all dimensions, and altogether
  integer :: nRoot_D(MaxDim) = 0, nRoot = 0

  character(len=*), parameter:: NameMod = "BATL_tree"

  integer, parameter :: UnitTmp_ = 9 ! same as used in SWMF

  ! Possible values for the status variable
  integer, parameter :: Unused_=1, Used_=2, Refine_=3, Coarsen_=4
  integer, parameter :: Skipped_ = -100

  ! Index for non-existing block and level differences
  integer, parameter :: NoBlock_ = Skipped_

  ! Neighbor information
  integer, allocatable :: DiLevelNei_IIIB(:,:,:,:), iBlockNei_IIIB(:,:,:,:)

  ! Maximum number of blocks including unused and skipped ones
  integer :: MaxBlockAll = 0

  ! Number of used blocks (leaves of the block tree)
  integer :: nBlockUsed = 0

  ! Number of blocks in the tree (some may not be used)
  integer :: nBlockTree = 0

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

  subroutine init_tree(nBlockProc, nBlockAll)

    use BATL_mpi, ONLY: nProc

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
    allocate(iBlockPeano_I(MaxBlock))
    allocate(iNode_BP(MaxBlock, 0:nProc-1))
    allocate(iBlockNei_IIIB(0:3,0:3,0:3,MaxBlock))
    allocate(DiLevelNei_IIIB(-1:1,-1:1,-1:1,MaxBlock))

    ! Initialize all elements and make neighbors unknown
    iBlockNei_IIIB  = NoBlock_
    DiLevelNei_IIIB = NoBlock_
    iBlockPeano_I   = NoBlock_

  end subroutine init_tree

  !==========================================================================
  subroutine clean_tree

    if(.not.allocated(iTree_IA)) RETURN
    deallocate(iTree_IA, iBlockPeano_I, iNode_BP, &
         iBlockNei_IIIB, DiLevelNei_IIIB)

    MaxBlock = 0

  end subroutine clean_tree
  !==========================================================================

  integer function i_block_new()

    ! Find a skipped element in the iTree_IA array

    integer :: iBlock

    do iBlock = 1, MaxBlockAll
       if(iTree_IA(Status_, iBlock) == Skipped_)then
          i_block_new = iBlock
          RETURN
       end if
    end do
    ! Could not find any skipped block
    i_block_new = -1

  end function i_block_new

  !==========================================================================

  subroutine set_tree_root(nRootIn_D, IsPeriodicIn_D)

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
    nBlockTree = nRoot

    ! Set neighbor info
    !do iBlock = 1, nRoot
    !   call find_neighbors(iBlock)
    !end do

  end subroutine set_tree_root

  !==========================================================================
  subroutine refine_tree_block(iBlock)

    integer, intent(in) :: iBlock

    integer :: iChild, DiChild, iLevelChild, iProc, iBlockProc
    integer :: iCoord_D(nDimTree)
    integer :: iDim, iBlockChild
    !----------------------------------------------------------------------

    iTree_IA(Status_, iBlock) = Unused_

    iLevelChild = iTree_IA(Level_, iBlock) + 1
    iProc       = iTree_IA(Proc_,  iBlock)
    iBlockProc  = iTree_IA(Block_, iBlock)

    ! Keep track of number of levels
    nLevel = max(nLevel, iLevelChild)
    if(nLevel > MaxLevel) &
         call CON_stop('Error in refine_tree_block: too many levels')

    iCoord_D = 2*iTree_IA(Coord1_:Coord0_+nDimTree, iBlock) - 1

    do iChild = Child1_, ChildLast_

       iBlockChild = i_block_new()

       iTree_IA(iChild, iBlock) = iBlockChild

       iTree_IA(Status_,   iBlockChild) = Used_
       iTree_IA(Level_,    iBlockChild) = iLevelChild
       iTree_IA(Parent_,   iBlockChild) = iBlock
       iTree_IA(Child1_:ChildLast_, iBlockChild) = NoBlock_

       ! This overwrites the two first children (saves memory)
       iTree_IA(Proc_,     iBlockChild) = iProc
       iTree_IA(Block_,    iBlockChild) = iBlockProc

       ! Calculate the coordinates of the child block
       DiChild = iChild - Child1_
       do iDim = 1, nDimTree
          iTree_IA(Coord0_+iDim, iBlockChild) = &
               iCoord_D(iDim) + ibits(DiChild, iDim-1, 1)
       end do

       ! The non-AMR coordinates remain the same as for the parent block
       do iDim = nDimTree+1, MaxDim
          iTree_IA(Coord0_+iDim, iBlockChild) = iTree_IA(Coord0_+iDim, iBlock)
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

  end subroutine refine_tree_block

  !==========================================================================
  subroutine coarsen_tree_block(iBlock)

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

  end subroutine coarsen_tree_block

  !==========================================================================
  subroutine get_tree_position(iBlock, PositionMin_D, PositionMax_D)

    integer, intent(in) :: iBlock
    real,    intent(out):: PositionMin_D(MaxDim), PositionMax_D(MaxDim)

    ! Calculate normalized position of the edges of block iblock.
    ! Zero is at the minimum boundary of the grid, one is at the max boundary

    integer :: iLevel
    integer :: MaxIndex_D(MaxDim)
    !------------------------------------------------------------------------
    iLevel = iTree_IA(Level_, iBlock)

    MaxIndex_D = nRoot_D
    MaxIndex_D(1:nDimTree) = MaxCoord_I(iLevel)*MaxIndex_D(1:nDimTree)

    ! Convert to real by adding -1.0 or 0.0 for the two edges, respectively
    PositionMin_D = (iTree_IA(Coord1_:CoordLast_,iBlock) - 1.0)/MaxIndex_D
    PositionMax_D = (iTree_IA(Coord1_:CoordLast_,iBlock) + 0.0)/MaxIndex_D

  end subroutine get_tree_position

  !==========================================================================
  subroutine find_tree_block(CoordIn_D, iBlock)

    ! Find the block that contains a point. The point coordinates should
    ! be given in generalized coordinates normalized to the domain size:
    ! CoordIn_D = (CoordOrig_D - CoordMin_D)/(CoordMax_D-CoordMin_D)

    real, intent(in):: CoordIn_D(MaxDim)
    integer, intent(out):: iBlock

    real :: Coord_D(MaxDim)
    integer :: iLevel, iChild
    integer :: Ijk_D(MaxDim), iCoord_D(nDimTree), iBit_D(nDimTree)
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
    iCoord_D = (Coord_D(1:nDimTree) - Ijk_D(1:nDimTree))*MaxCoord_I(nLevel)

    ! Go down the tree using bit information
    do iLevel = nLevel-1,0,-1
       iBit_D = ibits(iCoord_D, iLevel, 1)
       iChild = sum(iBit_D*MaxCoord_I(0:nDimTree-1)) + Child1_
       iBlock = iTree_IA(iChild, iBlock)

       if(iTree_IA(Status_, iBlock) == Used_) RETURN
    end do


  end subroutine find_tree_block

  !==========================================================================
  logical function is_point_inside_block(Position_D, iBlock)

    ! Check if position is inside block or not

    real,    intent(in):: Position_D(MaxDim)
    integer, intent(in):: iBlock

    real    :: PositionMin_D(MaxDim), PositionMax_D(MaxDim)
    !-------------------------------------------------------------------------
    call get_tree_position(iBlock, PositionMin_D, PositionMax_D)

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
       if(nDimTree < 3)then
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
          if(nDimTree < 2)then
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

             call find_tree_block( (/x, y, z/), jBlock)
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

    use BATL_mpi, ONLY: iProc, barrier_mpi

    character(len=*), intent(in):: NameFile
    integer :: nBlockAll

    !-------------------------------------------------------------------------
    call compact_tree(nBlockAll)

    if(iProc == 0)then
       open(UnitTmp_, file=NameFile, status='replace', form='unformatted')

       write(UnitTmp_) nBlockAll, nInfo
       write(UnitTmp_) nDimTree, nRoot_D
       write(UnitTmp_) iTree_IA(:,1:nBlockAll)

       close(UnitTmp_)
    end if
    call barrier_mpi

  end subroutine write_tree_file
  
  !==========================================================================

  subroutine read_tree_file(NameFile)

    character(len=*), intent(in):: NameFile
    integer :: nInfoIn, nBlockIn, nDimTreeIn, nRootIn_D(MaxDim)
    character(len=*), parameter :: NameSub = 'read_tree_file'
    !----------------------------------------------------------------------

    open(UnitTmp_, file=NameFile, status='old', form='unformatted')

    read(UnitTmp_) nBlockIn, nInfoIn
    if(nBlockIn > MaxBlock)then
       write(*,*) NameSub,' nBlockIn, MaxBlock=',nBlockIn, MaxBlock 
       call CON_stop(NameSub//' too many blocks in tree file!')
    end if
    read(UnitTmp_) nDimTreeIn, nRootIn_D
    if(nDimTreeIn /= nDimTree)then
       write(*,*) NameSub,' nDimTreeIn, nDimTree=',nDimTreeIn, nDimTree
       call CON_stop(NameSub//' nDimTree is different in tree file!')
    end if
    call set_tree_root(nRootIn_D, IsPeriodic_D)
    read(UnitTmp_) iTree_IA(:,1:nBlockIn)
    close(UnitTmp_)

    call order_tree

  end subroutine read_tree_file
  
  !==========================================================================
  subroutine distribute_tree(DoMove)

    ! Assign tree blocks to separate processors

    use BATL_mpi, ONLY: nProc

    ! Are nodes moved immediatly or just assigned new processor/block
    logical, intent(in):: DoMove

    integer :: nBlockPerProc, iPeano, iNode, iBlockTo, iProcTo
    !------------------------------------------------------------------------

    ! Create iBlockPeano_I
    call order_tree

    ! An upper estimate on the number of blocks per processor
    nBlockPerProc = (nBlockUsed-1)/nProc + 1

    do iPeano = 1, nBlockUsed
       iNode = iBlockPeano_I(iPeano)

       iProcTo  = (iPeano-1)/nBlockPerProc
       iBlockTo = modulo(iPeano-1, nBlockPerProc) + 1

       ! Assign new processor and block
       iTree_IA(ProcNew_, iNode) = iProcTo
       iTree_IA(BlockNew_,iNode) = iBlockTo

       if(.not.DoMove) CYCLE

       ! Move the node to new processor/block
       iTree_IA(Proc_:Block_, iNode) = iTree_IA(ProcNew_:BlockNew_, iNode)
       iNode_BP(iBlockTo, iProcTo)   = iNode

    end do

    

  end subroutine distribute_tree
  !==========================================================================

  subroutine order_tree

    ! Set iBlockPeano_I indirect index array according to 
    ! 1. root block order
    ! 2. Morton ordering for each root block

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

  subroutine show_tree(String)

    character(len=*), intent(in):: String

    character(len=10) :: Name
    character(len=200):: Header
    integer:: iInfo, iBlock
    !-----------------------------------------------------------------------
    Header = 'iBlock'
    do iInfo = 1, nInfo
       Name = NameTreeInfo_I(iInfo)
       Header(7*iInfo+1:7*(iInfo+1)-1) = Name(1:6)
    end do

    write(*,*) String
    write(*,*) trim(Header)
    do iBlock = 1, MaxBlockAll
       if(iTree_IA(Status_, iBlock) == Skipped_) CYCLE
       write(*,'(100i7)') iBlock, iTree_IA(:, iBlock)
    end do

  end subroutine show_tree
  !==========================================================================

  subroutine test_tree

    use BATL_mpi, ONLY: iProc

    integer :: iBlock, nBlockAll, Int_D(MaxDim)
    real:: CoordTest_D(MaxDim)

    logical :: DoTestMe
 
    character(len=*), parameter :: NameSub = 'test_tree'
    !-----------------------------------------------------------------------

    DoTestMe = iProc == 0

    if(DoTestMe)write(*,*)'Testing init_tree'
    call init_tree(50, 100)
    if(MaxBlock /= 50) &
         write(*,*)'init_mod_octtree faild, MaxBlock=',&
         MaxBlock, ' should be 50'

    if(MaxBlockAll /= 100) &
         write(*,*)'init_mod_octtree faild, MaxBlockAll=',&
         MaxBlockAll, ' should be 100'

    if(DoTestMe)write(*,*)'Testing i_block_new()'
    iBlock = i_block_new()
    if(iBlock /= 1) &
         write(*,*)'i_block_new() failed, iBlock=',iBlock,' should be 1'

    if(DoTestMe)write(*,*)'Testing set_tree_root'
    call set_tree_root( (/1,2,3/), (/.true., .true., .false./) )

    if(DoTestMe)call show_tree('after set_tree_root')

    if(any( nRoot_D /= (/1,2,3/) )) &
         write(*,*) 'set_tree_root failed, nRoot_D=',nRoot_D,&
         ' should be 1,2,3'

    Int_D = (/1,2,2/)

    if(any( iTree_IA(Coord1_:CoordLast_,4) /= Int_D )) &
         write(*,*) 'set_tree_root failed, coordinates of block four=',&
         iTree_IA(Coord1_:CoordLast_,4), ' should be ',Int_D(1:nDimTree)

    if(DoTestMe)write(*,*)'Testing find_tree_block'
    CoordTest_D = (/0.99,0.99,0.9/)
    call find_tree_block(CoordTest_D, iBlock)
    if(iBlock /= nRoot)write(*,*)'ERROR: Test find point failed, iBlock=',&
         iBlock,' instead of',nRoot

    if(.not.is_point_inside_block(CoordTest_D, iBlock)) &
         write(*,*)'ERROR: Test find point failed'
    
    if(DoTestMe)write(*,*)'Testing refine_tree_block'
    ! Refine the block where the point was found and find it again
    call refine_tree_block(iBlock)

    if(DoTestMe)call show_tree('after refine_tree_block')

    call find_tree_block(CoordTest_D,iBlock)
    if(.not.is_point_inside_block(CoordTest_D, iBlock)) &
         write(*,*)'ERROR: Test find point failed for iBlock=',iBlock

    ! Refine another block
    if(DoTestMe)write(*,*)'nRoot=',nRoot
    call refine_tree_block(nRoot-2)

    if(DoTestMe)call show_tree('after another refine_tree_block')

    if(DoTestMe)write(*,*)'Testing find_neighbors'
    call find_neighbors(5)
    if(DoTestMe)write(*,*)'DiLevelNei_IIIB(:,:,:,5)=',DiLevelNei_IIIB(:,:,:,5)
    if(DoTestMe)write(*,*)'iBlockNei_IIIB(:,:,:,5)=',iBlockNei_IIIB(:,:,:,5)

    if(DoTestMe)write(*,*)'Testing distribute_tree 1st'
    call distribute_tree(.false.)
    if(DoTestMe)write(*,*)'iBlockPeano_I =',iBlockPeano_I(1:22)
    if(DoTestMe)call show_tree('after distribute_tree 1st')

    if(DoTestMe)write(*,*)'Testing coarsen_tree_block'

    ! Coarsen back the last root block and find point again
    call coarsen_tree_block(nRoot)
    if(DoTestMe)call show_tree('after coarsen_tree_block')

    call find_tree_block(CoordTest_D,iBlock)
    if(iBlock /= nRoot)write(*,*)'ERROR: coarsen_tree_block faild, iBlock=',&
         iBlock,' instead of',nRoot
    if(.not.is_point_inside_block(CoordTest_D, iBlock)) &
         write(*,*)'ERROR: is_point_inside_block failed'


    if(DoTestMe)write(*,*)'Testing distribute_tree 2nd'
    call distribute_tree(.true.)
    if(DoTestMe)write(*,*)'iBlockPeano_I =',iBlockPeano_I(1:22)

    if(DoTestMe)write(*,*)'Testing compact_tree'
    call compact_tree(nBlockAll)
    if(DoTestMe)call show_tree('after compact_tree')

    if(iTree_IA(Status_, nBlockAll+1) /= Skipped_) &
         write(*,*)'ERROR: compact_tree faild, nBlockAll=', nBlockAll, &
         ' but status of next block is', iTree_IA(Status_, nBlockAll+1), &
         ' instead of ',Skipped_
    if(any(iTree_IA(Status_, 1:nBlockAll) == Skipped_)) &
         write(*,*)'ERROR: compact_tree faild, nBlockAll=', nBlockAll, &
         ' but iTree_IA(Status_, 1:nBlockAll)=', &
         iTree_IA(Status_, 1:nBlockAll),' contains skipped=',Skipped_
    call find_tree_block(CoordTest_D,iBlock)
    if(iBlock /= nRoot)write(*,*)'ERROR: compact_tree faild, iBlock=',&
         iBlock,' instead of',nRoot
    if(.not.is_point_inside_block(CoordTest_D, iBlock)) &
         write(*,*)'ERROR: is_point_inside_block failed'

    if(DoTestMe)write(*,*)'Testing distribute_tree 3rd'
    call distribute_tree(.true.)
    if(DoTestMe)write(*,*)'iBlockPeano_I =',iBlockPeano_I(1:22)

    if(DoTestMe)write(*,*)'Testing write_tree_file'
    call write_tree_file('tree.rst')

    if(DoTestMe)write(*,*)'Testing read_tree_file'
    iTree_IA = NoBlock_
    nRoot_D = 0
    call read_tree_file('tree.rst')
    if(DoTestMe)call show_tree('after read_tree')

    call find_tree_block(CoordTest_D,iBlock)
    if(iBlock /= nRoot)write(*,*)'ERROR: compact_tree faild, iBlock=',&
         iBlock,' instead of',nRoot

    if(DoTestMe)write(*,*)'Testing distribute_tree 4th'
    call distribute_tree(.true.)
    if(DoTestMe)write(*,*)'iBlockPeano_I =',iBlockPeano_I(1:22)

    if(DoTestMe)write(*,*)'Testing clean_tree'
    call clean_tree
    if(DoTestMe)write(*,*)'MaxBlock=', MaxBlock

  end subroutine test_tree

end module BATL_tree
