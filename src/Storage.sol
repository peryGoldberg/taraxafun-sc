// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract FunStorage is Ownable {
// משמש כמסד נתונים לחוזים החכמים


    struct FunDetails { //מאחסן נתונים על הטוקנים שנוצרו
        address funAddress; 
        address tokenAddress;
        address funOwner;
        string name;
        string symbol;
        string data;
        uint256 totalSupply;
        uint256 initialLiquidity;
        uint256 createdOn;
    }

    FunDetails[] public funContracts; //funDetails מערך מסוג אוביקט  
    
    uint256 public funCount;

    mapping(address => bool) public deployer; 
    mapping(address => uint256) public funContractToIndex;
    mapping(address => uint256) public tokenContractToIndex;
    mapping(address => uint256) public ownerToFunCount;
    mapping(address => mapping(uint256 => uint256)) public ownerIndexToStorageIndex;
    mapping(address => address) public funContractToOwner;
    mapping(address => uint256) public funContractToOwnerCount;

    constructor() Ownable(msg.sender) {}

    function addFunContract( //מקבלת נתונים של חוזה של טוקן ובודקת תקינות ומעדכנת ושומרת
        address _funOwner,
        address _funAddress,
        address _tokenAddress,
        string memory _name,
        string memory _symbol,
        string memory _data,
        uint256 _totalSupply,
        uint256 _initialLiquidity
    ) external {

        require(deployer[msg.sender], "not deployer");

        FunDetails memory newFun = FunDetails({
            funAddress: _funAddress,
            tokenAddress: _tokenAddress,
            funOwner: _funOwner,
            name: _name,
            symbol: _symbol,
            data: _data,
            totalSupply: _totalSupply,
            initialLiquidity: _initialLiquidity,
            createdOn: block.timestamp
        });

        funContracts.push(newFun);
        funContractToIndex[_funAddress] = funContracts.length - 1;
        tokenContractToIndex[_tokenAddress] = funContracts.length - 1;
        funContractToOwner[_funAddress] = _funOwner;
        funContractToOwnerCount[_funAddress] = ownerToFunCount[_funOwner]; 
        ownerIndexToStorageIndex[_funOwner][ownerToFunCount[_funOwner]] = funCount;
        ownerToFunCount[_funOwner]++;
        funCount++;
    }

    function getFunContract( //מקבל אינדקס ומחזיר את הכתובת של החוזה
        uint256 index
    ) public view returns (FunDetails memory) {
        return funContracts[index];
    }

    function getFunContractIndex(//מקבל כתובת ומחזיר את האינדקס
        address _funContract
    ) public view returns (uint256) {
        return funContractToIndex[_funContract];
    }

    function getTotalContracts() public view returns (uint) { // מחזיר את כמות הטוקנים שהופנקו דרך המערכת
        return funContracts.length;
    }

    function getFunContractOwner(// מקבל כתובת טוקן ומחזיר את הבעלים שלה
        address _funContract
    ) public view returns (address) {
        return funContractToOwner[_funContract];
    }

    function addDeployer(address _deployer) public onlyOwner {// מקבל כתובת ומוסיף שותף שיכול לפרוס את החוזה 
        require(!deployer[_deployer], "already added");
        deployer[_deployer] = true;
    }

    function removeDeployer(address _deployer) public onlyOwner { //מוחק כתובת 
        require(deployer[_deployer], "not deployer");
        deployer[_deployer] = false;
    }

    function emergencyWithdraw() public onlyOwner {//  מאפשר לבעל החוזה למשוך את יתרת החוזה במקרה חרום 
        uint256 balance = address(this).balance;
        payable(owner()).transfer(balance);
    }
}